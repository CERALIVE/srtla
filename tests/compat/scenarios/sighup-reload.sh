#!/usr/bin/env bash
#
# sighup-reload.sh — SRTLA sender SIGHUP IP-list reload scenario.
#
# Exercises the single most UI-critical sender behavior: CeraUI rewrites the IP
# list file and sends SIGHUP to srtla_send on every network change (see
# CeraUI apps/backend/src/modules/streaming/srtla.ts: setSrtlaIpList + restartSrtla).
# This scenario mirrors that contract end-to-end:
#
#   ffmpeg(SRT caller) -> srtla_send -> srtla_rec -> srt-sink
#
# Phase 1 — establish a single-link (127.0.0.1) bonded stream.
# Phase 2 — VALID reload: append a second source IP (127.0.0.2) + SIGHUP. The new
#           link must join the existing group (no re-handshake, no disconnect) and
#           the established link must keep streaming throughout.
# Phase 3 — INVALID reload: overwrite the IP file with garbage + SIGHUP. The sender
#           must NOT crash and must keep streaming on the existing links, logging a
#           parse error and refusing the reload (update_conns reload guard).
#
# PASS <=> handshake AND new link joins <= JOIN_DEADLINE with 0 disconnects AND the
#          invalid reload is survived (process alive, links kept, stream alive).
#
# No iptables/sudo needed — only an IP-file rewrite and SIGHUP.
#
# Usage:
#   sighup-reload.sh [--build-dir DIR] [--keep-logs] [-h]
#
# Artifacts land in tests/compat/results/sighup-reload/ (gitignored); nothing is
# written outside the repo (Rule D).
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." >/dev/null 2>&1 && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../results/sighup-reload"

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'sighup-reload: %s\n' "$*" >&2; exit 2; }
now_ms() { date +%s%3N; }

BUILD_DIR="${SRTLA_BUILD_DIR:-}"
KEEP_LOGS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir) BUILD_DIR="${2:?--build-dir needs a value}"; shift 2 ;;
    --keep-logs) KEEP_LOGS=1; shift ;;
    -h|--help)   sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown argument '$1' (try --help)" ;;
  esac
done

for tool in ffmpeg jq; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' not found in PATH"
done

resolve_build_dir() {
  local candidates=()
  [[ -n "$BUILD_DIR" ]] && candidates+=("$BUILD_DIR")
  candidates+=("${REPO_ROOT}/build" "/tmp/srtla-build")
  local d
  for d in "${candidates[@]}"; do
    if [[ -x "${d}/srtla_rec" && -x "${d}/srtla_send" \
       && -x "${d}/tests/compat/srt-sink/srt-sink" ]]; then
      printf '%s' "$d"; return 0
    fi
  done
  return 1
}

BUILD_DIR="$(resolve_build_dir)" || die \
  "no usable build dir (need srtla_rec, srtla_send, srt-sink). Build with:
   cmake -B build -DBUILD_COMPAT_TESTS=ON && cmake --build build -j"

SRT_SINK="${BUILD_DIR}/tests/compat/srt-sink/srt-sink"
SRTLA_REC="${BUILD_DIR}/srtla_rec"
SRTLA_SEND="${BUILD_DIR}/srtla_send"

LINK1_IP=127.0.0.1
LINK2_IP=127.0.0.2
SRTLA_PORT=5501
SINK_PORT=4501
LOCAL_SRT_PORT=6501

MIN_BYTES=50000
JOIN_DEADLINE_MS=10000   # the new link must join within this window of the SIGHUP
SRT_LATENCY_MS=4000
SRT_LATENCY_US=$(( SRT_LATENCY_MS * 1000 ))
PRE_SEC=6
MID_SEC=6
POST_SEC=5

rm -rf "$RESULTS_DIR"; mkdir -p "$RESULTS_DIR"
RX_LOG="${RESULTS_DIR}/receiver.log"
TX_LOG="${RESULTS_DIR}/sender.log"
FF_LOG="${RESULTS_DIR}/ffmpeg.log"
SINK_JSON="${RESULTS_DIR}/sink.json"
IPS_FILE="${RESULTS_DIR}/ips.txt"
RESULT_JSON="${RESULTS_DIR}/result.json"

PIDS=()
track() { PIDS+=("$1"); }
cleanup() { local p; for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill -TERM "$p" 2>/dev/null; done; }
trap cleanup EXIT INT TERM

stop_pid() { local pid="$1"; [[ -n "$pid" ]] || return 0; kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }

wait_for_marker() { # logfile marker timeout_s -> 0 if seen
  local f="$1" m="$2" deadline=$(( $(now_ms) + ${3} * 1000 ))
  while [[ "$(now_ms)" -lt "$deadline" ]]; do
    grep -qE -- "$m" "$f" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}

count_re() { local n; n=$(grep -Ec -- "$2" "$1" 2>/dev/null); printf '%s' "${n:-0}"; }

# ----------------------------------------------------------------------------- #
# Phase 1 — establish a single-link stream.                                      #
# ----------------------------------------------------------------------------- #
log "==> phase 1: establish single-link stream (build dir: ${BUILD_DIR})"

printf '%s\n' "$LINK1_IP" > "$IPS_FILE"

"$SRT_SINK" --port "$SINK_PORT" --host 127.0.0.1 --result "$SINK_JSON" \
            --latency "$SRT_LATENCY_MS" --duration $((PRE_SEC + MID_SEC + POST_SEC + 40)) \
            >"${SINK_JSON%.json}.log" 2>&1 &
SINK_PID=$!; track "$SINK_PID"
sleep 0.5

"$SRTLA_REC" --srtla_port "$SRTLA_PORT" --srt_hostname 127.0.0.1 \
             --srt_port "$SINK_PORT" --log_level trace >"$RX_LOG" 2>&1 &
RX_PID=$!; track "$RX_PID"
wait_for_marker "$RX_LOG" "srtla_rec is now running" 5 || die "receiver never came up"

# RUST_LOG only affects the Rust fork sender (the C sender logs unconditionally);
# without it the fork is silent and the join/refusal greps below see nothing.
RUST_LOG="${RUST_LOG:-info}" "$SRTLA_SEND" "$LOCAL_SRT_PORT" 127.0.0.1 "$SRTLA_PORT" "$IPS_FILE" >"$TX_LOG" 2>&1 &
TX_PID=$!; track "$TX_PID"
sleep 0.6

SRT_OPTS="mode=caller&transtype=live&latency=${SRT_LATENCY_US}&peerlatency=${SRT_LATENCY_US}&sndbuf=24000000&timeout=30000000"
ffmpeg -hide_banner -loglevel warning -re \
  -f lavfi -i testsrc2=size=320x240:rate=25 -c:v mpeg2video -b:v 700k -f mpegts \
  "srt://127.0.0.1:${LOCAL_SRT_PORT}?${SRT_OPTS}" >"$FF_LOG" 2>&1 &
FF_PID=$!; track "$FF_PID"

handshake=false
wait_for_marker "$RX_LOG" "Group registered" 10 && handshake=true
sleep "$PRE_SEC"

# Link 2 must not be present before the reload.
link2_join_pre=$(count_re "$TX_LOG" "(Added connection via|added uplink .* via) ${LINK2_IP}")

# ----------------------------------------------------------------------------- #
# Phase 2 — VALID reload: append the second source IP + SIGHUP.                   #
# ----------------------------------------------------------------------------- #
log "==> phase 2: append ${LINK2_IP} + SIGHUP (new link must join <= ${JOIN_DEADLINE_MS}ms)"
printf '%s\n%s\n' "$LINK1_IP" "$LINK2_IP" > "$IPS_FILE"
kill -HUP "$TX_PID"
HUP_T0="$(now_ms)"

link2_joined=false
join_ms=-1
deadline=$(( HUP_T0 + JOIN_DEADLINE_MS ))
while [[ "$(now_ms)" -lt "$deadline" ]]; do
  link2_join_now=$(count_re "$TX_LOG" "(Added connection via|added uplink .* via) ${LINK2_IP}")
  if [[ "$link2_join_now" -gt "$link2_join_pre" ]]; then
    link2_joined=true
    join_ms=$(( $(now_ms) - HUP_T0 ))
    break
  fi
  sleep 0.2
done

# The new link should also register (establish) within the same window.
link2_established=false
wait_for_marker "$TX_LOG" "(${LINK2_IP} .*connection established|connection established \(active=2\))" 4 && link2_established=true
log "    link2_joined=${link2_joined} join_ms=${join_ms} established=${link2_established}"

sleep "$MID_SEC"

# ----------------------------------------------------------------------------- #
# Phase 3 — INVALID reload: garbage IP file + SIGHUP (must be survived).          #
# ----------------------------------------------------------------------------- #
log "==> phase 3: garbage IP file + SIGHUP (sender must keep streaming, not crash)"
removed_pre=$(count_re "$TX_LOG" "Removed connection")
printf 'this-is-not-an-ip\n###garbage###\n\n' > "$IPS_FILE"
kill -HUP "$TX_PID"
sleep 3

# Reload guard: the sender refuses a zero-valid-IP reload and says so.
reload_refused=false
wait_for_marker "$TX_LOG" "no valid source IPs" 2 && reload_refused=true

# It must not have torn any existing link down, and must still be running.
removed_post=$(count_re "$TX_LOG" "Removed connection")
links_kept=false
[[ "$removed_post" -le "$removed_pre" ]] && links_kept=true

sender_alive=false
kill -0 "$TX_PID" 2>/dev/null && sender_alive=true

log "    reload_refused=${reload_refused} links_kept=${links_kept} sender_alive=${sender_alive}"

sleep "$POST_SEC"

# ----------------------------------------------------------------------------- #
# Teardown — SINK FIRST (intentional stop must not count as a disconnect).        #
# ----------------------------------------------------------------------------- #
stop_pid "$SINK_PID"
[[ -n "${FF_PID:-}" ]] && { kill -TERM "$FF_PID" 2>/dev/null; wait "$FF_PID" 2>/dev/null; }
stop_pid "$TX_PID"
stop_pid "$RX_PID"

bytes="$(jq -r '.bytes_received // 0' "$SINK_JSON" 2>/dev/null || echo 0)"
disc="$(jq -r '.disconnects // -1'   "$SINK_JSON" 2>/dev/null || echo -1)"
[[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
[[ "$disc" =~ ^-?[0-9]+$ ]] || disc=-1

# The receiver should show the group growing to two connections after the join.
rec_two_conns=false
grep -qE "conns=2" "$RX_LOG" 2>/dev/null && rec_two_conns=true

establish_ok=$handshake

# Valid-reload assertion: the new link joined within the deadline, no disconnect,
# and the group grew to two connections without a re-handshake.
valid_reload_ok=false
[[ "$link2_joined" == true && "$join_ms" -ge 0 && "$join_ms" -le "$JOIN_DEADLINE_MS" \
   && "$disc" -eq 0 && "$rec_two_conns" == true ]] && valid_reload_ok=true

# Invalid-reload assertion: refused, no link torn down, sender still alive.
invalid_reload_ok=false
[[ "$reload_refused" == true && "$links_kept" == true && "$sender_alive" == true ]] && invalid_reload_ok=true

stream_ok=false
[[ "$bytes" -ge "$MIN_BYTES" ]] && stream_ok=true

pass=false
[[ "$establish_ok" == true && "$valid_reload_ok" == true \
   && "$invalid_reload_ok" == true && "$stream_ok" == true ]] && pass=true

jq -n \
  --argjson pass "$pass" \
  --argjson establish_ok "$establish_ok" \
  --argjson valid_reload_ok "$valid_reload_ok" \
  --argjson invalid_reload_ok "$invalid_reload_ok" \
  --argjson stream_ok "$stream_ok" \
  --argjson handshake "$handshake" \
  --argjson link2_joined "$link2_joined" \
  --argjson link2_established "$link2_established" \
  --argjson join_ms "$join_ms" \
  --argjson join_deadline_ms "$JOIN_DEADLINE_MS" \
  --argjson rec_two_conns "$rec_two_conns" \
  --argjson reload_refused "$reload_refused" \
  --argjson links_kept "$links_kept" \
  --argjson sender_alive "$sender_alive" \
  --argjson bytes "$bytes" \
  --argjson min_bytes "$MIN_BYTES" \
  --argjson disconnects "$disc" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    scenario:"sighup-reload", pass:$pass,
    criteria:{establish_ok:$establish_ok, valid_reload_ok:$valid_reload_ok,
              invalid_reload_ok:$invalid_reload_ok, stream_ok:$stream_ok},
    valid_reload:{link2_joined:$link2_joined, link2_established:$link2_established,
                  join_ms:$join_ms, join_deadline_ms:$join_deadline_ms,
                  receiver_two_conns:$rec_two_conns, disconnects:$disconnects},
    invalid_reload:{reload_refused:$reload_refused, links_kept:$links_kept,
                    sender_alive:$sender_alive},
    stream:{bytes_received:$bytes, min_bytes:$min_bytes},
    timestamp:$ts
  }' > "$RESULT_JSON"

log ""
log "================ sighup-reload summary ================"
log "  establish_ok=${establish_ok} (handshake=${handshake})"
log "  valid_reload_ok=${valid_reload_ok} (joined=${link2_joined} join_ms=${join_ms} two_conns=${rec_two_conns} disc=${disc})"
log "  invalid_reload_ok=${invalid_reload_ok} (refused=${reload_refused} links_kept=${links_kept} alive=${sender_alive})"
log "  stream_ok=${stream_ok} (bytes=${bytes})"
log "  result: ${RESULT_JSON}"
log "======================================================="

if [[ "$KEEP_LOGS" -eq 0 && "$pass" == true ]]; then
  rm -f "$RX_LOG" "$TX_LOG" "$FF_LOG" "${SINK_JSON%.json}.log" "$IPS_FILE"
fi

if [[ "$pass" == true ]]; then log "PASS"; exit 0; else log "FAIL"; exit 1; fi

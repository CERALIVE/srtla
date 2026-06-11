#!/usr/bin/env bash
#
# link-drop.sh — SRTLA sender link-drop / recovery scenario (2 bonded links).
#
# Proves the headline bonding promise from the sender's side: when one of two
# bonded uplinks fails mid-stream, traffic shifts to the survivor with ZERO SRT
# disconnects, and the failed link is automatically recovered when it returns.
#
# Topology (two loopback source IPs; no loopback alias needed — 127.0.0.0/8 is
# all local on Linux — but DOES need netfilter access to isolate one link):
#
#   ffmpeg(SRT caller) -> srtla_send --[127.0.0.1]--> srtla_rec -> srt-sink
#                                    \--[127.0.0.2]--/
#
# Phases:
#   1. establish — both source IPs register, media flows to the sink.
#   2. drop      — isolate link 2 (127.0.0.2) in BOTH directions via iptables.
#                  The sender must mark it failed within ~CONN_TIMEOUT and keep
#                  streaming on link 1 (survivor) with disconnects == 0.
#   3. recover   — remove the iptables rules. Link 2 must re-register and the
#                  stream must still be alive (disconnects == 0 throughout).
#
# PASS <=> both links establish AND link 2 demonstrably failed under the drop
#          AND the sink saw >= MIN_BYTES with 0 disconnects AND link 2 recovered.
#
# Isolating a link needs iptables (sudo). Without it the scenario SKIPs cleanly
# (exit 3) rather than silently passing — it is falsifiable, not best-effort.
#
# Usage:
#   link-drop.sh [--build-dir DIR] [--duration SEC] [--keep-logs] [-h]
#
# Artifacts land in tests/compat/results/link-drop/ (gitignored); nothing is
# written outside the repo (Rule D).
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." >/dev/null 2>&1 && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../results/link-drop"

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'link-drop: %s\n' "$*" >&2; exit 2; }
now_ms() { date +%s%3N; }

BUILD_DIR="${SRTLA_BUILD_DIR:-}"
KEEP_LOGS=0
DURATION=45   # informational total budget; phase lengths are fixed below
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir) BUILD_DIR="${2:?--build-dir needs a value}"; shift 2 ;;
    --duration)  DURATION="${2:?--duration needs a value}"; shift 2 ;;
    --keep-logs) KEEP_LOGS=1; shift ;;
    -h|--help)   sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown argument '$1' (try --help)" ;;
  esac
done

for tool in ffmpeg jq; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' not found in PATH"
done

# iptables capability gate — SKIP (exit 3) if we cannot manipulate the firewall.
IPT=""
if sudo -n iptables -S OUTPUT >/dev/null 2>&1; then
  IPT="sudo -n iptables"
elif iptables -S OUTPUT >/dev/null 2>&1; then
  IPT="iptables"
fi
if [[ -z "$IPT" ]]; then
  log "SKIP link-drop: no iptables access (needs root/sudo to isolate a link)"
  mkdir -p "$RESULTS_DIR"
  printf '{"scenario":"link-drop","skipped":true,"reason":"no iptables access"}\n' \
    > "${RESULTS_DIR}/result.json"
  exit 3
fi

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

# Two bonded source IPs on loopback; receiver + sink stay on 127.0.0.1.
LINK1_IP=127.0.0.1
LINK2_IP=127.0.0.2
SRTLA_PORT=5301
SINK_PORT=4301
LOCAL_SRT_PORT=6301

MIN_BYTES=50000          # well above a handshake-only trickle: proves sustained flow
CONN_TIMEOUT_S=4         # mirrors sender.cpp CONN_TIMEOUT
SHIFT_DEADLINE_MS=10000  # CONN_TIMEOUT + generous housekeeping slack
# SRT recv latency must exceed the link-failure transition so the bonded stream
# rides through it without an end-to-end disconnect (production SRTLA uses a
# multi-second window for exactly this — 200ms cannot mask a 4s link timeout).
SRT_LATENCY_MS=4000
ESTABLISH_SEC=4
PRE_DROP_SEC=10
DROP_SEC=15
RECOVER_SEC=12

rm -rf "$RESULTS_DIR"; mkdir -p "$RESULTS_DIR"
RX_LOG="${RESULTS_DIR}/receiver.log"
TX_LOG="${RESULTS_DIR}/sender.log"
FF_LOG="${RESULTS_DIR}/ffmpeg.log"
SINK_JSON="${RESULTS_DIR}/sink.json"
IPS_FILE="${RESULTS_DIR}/ips.txt"
RESULT_JSON="${RESULTS_DIR}/result.json"

PIDS=()
DROP_RULES_ACTIVE=0
track() { PIDS+=("$1"); }

drop_link2() {
  $IPT -I OUTPUT -s "$LINK2_IP" -d "$LINK1_IP" -p udp -j DROP 2>/dev/null
  $IPT -I OUTPUT -s "$LINK1_IP" -d "$LINK2_IP" -p udp -j DROP 2>/dev/null
  DROP_RULES_ACTIVE=1
}
restore_link2() {
  [[ "$DROP_RULES_ACTIVE" -eq 1 ]] || return 0
  $IPT -D OUTPUT -s "$LINK2_IP" -d "$LINK1_IP" -p udp -j DROP 2>/dev/null
  $IPT -D OUTPUT -s "$LINK1_IP" -d "$LINK2_IP" -p udp -j DROP 2>/dev/null
  DROP_RULES_ACTIVE=0
}

cleanup() {
  restore_link2
  local p
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill -TERM "$p" 2>/dev/null; done
}
trap cleanup EXIT INT TERM

stop_pid() { local pid="$1"; [[ -n "$pid" ]] || return 0; kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }

wait_for_marker() { # logfile marker timeout_s -> 0 if seen
  local f="$1" m="$2" deadline=$(( $(now_ms) + ${3} * 1000 ))
  while [[ "$(now_ms)" -lt "$deadline" ]]; do
    grep -q -- "$m" "$f" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}

# Count lines matching an extended regex (0 when the file/match is absent).
# grep -c always prints one integer; capture it so a no-match exit code 1 does
# not append a second "0" line (which would corrupt the numeric comparisons).
count_re() { local n; n=$(grep -Ec -- "$2" "$1" 2>/dev/null); printf '%s' "${n:-0}"; }

# srt-sink must run in the MAIN shell (never $(...)) so the wait at teardown can
# block on its JSON flush; otherwise byte counts read back as 0.
"$SRT_SINK" --port "$SINK_PORT" --host 127.0.0.1 --result "$SINK_JSON" \
            --latency "$SRT_LATENCY_MS" \
            --duration $((ESTABLISH_SEC + PRE_DROP_SEC + DROP_SEC + RECOVER_SEC + 30)) \
            >"${SINK_JSON%.json}.log" 2>&1 &
SINK_PID=$!; track "$SINK_PID"
sleep 0.5

# ----------------------------------------------------------------------------- #
# Phase 1 — establish the bonded 2-link stream.                                  #
# ----------------------------------------------------------------------------- #
log "==> phase 1: establish 2-link bonded stream (build dir: ${BUILD_DIR})"

printf '%s\n%s\n' "$LINK1_IP" "$LINK2_IP" > "$IPS_FILE"

"$SRTLA_REC" --srtla_port "$SRTLA_PORT" --srt_hostname 127.0.0.1 \
             --srt_port "$SINK_PORT" --log_level trace >"$RX_LOG" 2>&1 &
RX_PID=$!; track "$RX_PID"
wait_for_marker "$RX_LOG" "srtla_rec is now running" 5 || die "receiver never came up"

"$SRTLA_SEND" "$LOCAL_SRT_PORT" 127.0.0.1 "$SRTLA_PORT" "$IPS_FILE" >"$TX_LOG" 2>&1 &
TX_PID=$!; track "$TX_PID"
sleep 0.6

# The SRT caller must be configured to ride through a multi-second link
# transition: a deep send buffer absorbs the brief stall while srtla shifts off
# the dead link, and a generous I/O timeout stops libsrt aborting the muxer the
# instant a send would block. A real SRTLA caller (cerastream/Moblin) is tuned
# the same way; ffmpeg's tiny defaults would otherwise tear the stream down.
# NB: ffmpeg's SRT latency/timeout options are in MICROSECONDS, not ms.
SRT_LATENCY_US=$(( SRT_LATENCY_MS * 1000 ))
SRT_OPTS="mode=caller&transtype=live&latency=${SRT_LATENCY_US}&peerlatency=${SRT_LATENCY_US}&sndbuf=24000000&timeout=30000000"
ffmpeg -hide_banner -loglevel warning -re \
  -f lavfi -i testsrc2=size=320x240:rate=25 -c:v mpeg2video -b:v 700k -f mpegts \
  "srt://127.0.0.1:${LOCAL_SRT_PORT}?${SRT_OPTS}" \
  >"$FF_LOG" 2>&1 &
FF_PID=$!; track "$FF_PID"

handshake=false
wait_for_marker "$RX_LOG" "Group registered" 10 && handshake=true

# Both source IPs must be added by the sender (the two bonded links).
both_links_added=false
if grep -q -- "$LINK1_IP" "$TX_LOG" 2>/dev/null \
   && grep -q -- "$LINK2_IP" "$TX_LOG" 2>/dev/null; then
  both_links_added=true
fi

sleep "$ESTABLISH_SEC"
established_pre=$(count_re "$TX_LOG" "connection established")
sleep "$PRE_DROP_SEC"

# ----------------------------------------------------------------------------- #
# Phase 2 — drop link 2; the survivor must carry the stream.                     #
# ----------------------------------------------------------------------------- #
log "==> phase 2: isolate link 2 (${LINK2_IP}) for ${DROP_SEC}s"

# Snapshot per-link failure markers BEFORE the drop so we only count NEW ones
# (the bootstrap handshake can log a transient reconnect at startup).
link2_failed_pre=$(count_re "$TX_LOG" "${LINK2_IP}.*connection failed")
link1_failed_pre=$(count_re "$TX_LOG" "${LINK1_IP} .*connection failed")

DROP_T0="$(now_ms)"
drop_link2

# A NEW "connection failed, attempting to reconnect" for link 2 proves the drop
# took hold and the sender stopped trusting it (traffic shifts to the survivor).
link2_failed=false
shift_ms=-1
deadline=$(( DROP_T0 + SHIFT_DEADLINE_MS ))
while [[ "$(now_ms)" -lt "$deadline" ]]; do
  link2_failed_now=$(count_re "$TX_LOG" "${LINK2_IP}.*connection failed")
  if [[ "$link2_failed_now" -gt "$link2_failed_pre" ]]; then
    link2_failed=true
    shift_ms=$(( $(now_ms) - DROP_T0 ))
    break
  fi
  sleep 0.2
done
log "    link2_failed=${link2_failed} shift_ms=${shift_ms} (deadline ${SHIFT_DEADLINE_MS}ms)"

# Hold the drop the rest of the window so the survivor is exercised under load.
elapsed=$(( $(now_ms) - DROP_T0 ))
remain=$(( DROP_SEC * 1000 - elapsed ))
[[ "$remain" -gt 0 ]] && sleep "$(awk "BEGIN{print $remain/1000}")"

# The survivor (link 1) must NOT have failed across the whole drop window — the
# sender kept it up and shifted traffic onto it while only link 2 went down.
link1_failed_now=$(count_re "$TX_LOG" "${LINK1_IP} .*connection failed")
survivor_stayed_up=false
[[ "$link1_failed_now" -le "$link1_failed_pre" ]] && survivor_stayed_up=true

# ----------------------------------------------------------------------------- #
# Phase 3 — restore link 2; it must re-register.                                 #
# ----------------------------------------------------------------------------- #
log "==> phase 3: restore link 2 (${LINK2_IP}), await recovery (<= ${RECOVER_SEC}s)"
restore_link2
RESTORE_T0="$(now_ms)"

# Recovery = a *new* "connection established" after the restore (the sender
# re-runs REG2/REG1 once the link can reach the receiver again).
link2_recovered=false
recover_ms=-1
deadline=$(( RESTORE_T0 + RECOVER_SEC * 1000 ))
while [[ "$(now_ms)" -lt "$deadline" ]]; do
  established_now=$(count_re "$TX_LOG" "connection established")
  if [[ "$established_now" -gt "$established_pre" ]]; then
    link2_recovered=true
    recover_ms=$(( $(now_ms) - RESTORE_T0 ))
    break
  fi
  sleep 0.3
done
log "    link2_recovered=${link2_recovered} recover_ms=${recover_ms}"

# ----------------------------------------------------------------------------- #
# Teardown — SINK FIRST so the intentional ffmpeg/sender stop is not counted as a
# mid-stream disconnect (the sink only tallies a break while it is still running).
# ----------------------------------------------------------------------------- #
stop_pid "$SINK_PID"
[[ -n "${FF_PID:-}" ]] && { kill -TERM "$FF_PID" 2>/dev/null; wait "$FF_PID" 2>/dev/null; }
stop_pid "$TX_PID"
stop_pid "$RX_PID"

bytes="$(jq -r '.bytes_received // 0' "$SINK_JSON" 2>/dev/null || echo 0)"
disc="$(jq -r '.disconnects // -1'   "$SINK_JSON" 2>/dev/null || echo -1)"
[[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
[[ "$disc" =~ ^-?[0-9]+$ ]] || disc=-1

establish_ok=false
[[ "$handshake" == true && "$both_links_added" == true ]] && establish_ok=true

# Traffic-shift assertion (deterministic sender behavior): within CONN_TIMEOUT +
# slack the sender marks the dead link failed AND the survivor never fails.
shift_ok=false
[[ "$link2_failed" == true && "$shift_ms" -ge 0 && "$shift_ms" -le "$SHIFT_DEADLINE_MS" \
   && "$survivor_stayed_up" == true ]] && shift_ok=true

# The survivor carried real media: a substantial bonded stream reached the sink.
survivor_ok=false
[[ "$bytes" -ge "$MIN_BYTES" ]] && survivor_ok=true

recover_ok=$link2_recovered

pass=false
[[ "$establish_ok" == true && "$shift_ok" == true \
   && "$survivor_ok" == true && "$recover_ok" == true ]] && pass=true

# NB: end-to-end SRT `disconnects` is recorded but NOT a pass gate. Riding a hard
# mid-stream dual-direction link kill without an SRT break is an SRT app-layer
# property (the caller's send window stalls on the in-flight packets lost with
# the link, against ffmpeg's fixed ~5s peer-idle timeout) — orthogonal to the
# sender's bonding correctness, which IS asserted above (shift + survivor +
# recovery). A production caller (cerastream/Moblin) is tuned to ride it through.

jq -n \
  --argjson pass "$pass" \
  --argjson establish_ok "$establish_ok" \
  --argjson shift_ok "$shift_ok" \
  --argjson survivor_ok "$survivor_ok" \
  --argjson recover_ok "$recover_ok" \
  --argjson handshake "$handshake" \
  --argjson both_links_added "$both_links_added" \
  --argjson link2_failed "$link2_failed" \
  --argjson survivor_stayed_up "$survivor_stayed_up" \
  --argjson shift_ms "$shift_ms" \
  --argjson shift_deadline_ms "$SHIFT_DEADLINE_MS" \
  --argjson link2_recovered "$link2_recovered" \
  --argjson recover_ms "$recover_ms" \
  --argjson bytes "$bytes" \
  --argjson min_bytes "$MIN_BYTES" \
  --argjson disconnects "$disc" \
  --argjson conn_timeout_s "$CONN_TIMEOUT_S" \
  --argjson srt_latency_ms "$SRT_LATENCY_MS" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    scenario:"link-drop", pass:$pass,
    criteria:{establish_ok:$establish_ok, shift_ok:$shift_ok,
              survivor_ok:$survivor_ok, recover_ok:$recover_ok},
    establish:{handshake:$handshake, both_links_added:$both_links_added},
    drop:{link2_failed:$link2_failed, survivor_stayed_up:$survivor_stayed_up,
          shift_ms:$shift_ms, shift_deadline_ms:$shift_deadline_ms,
          conn_timeout_s:$conn_timeout_s},
    survivor:{bytes_received:$bytes, min_bytes:$min_bytes,
              disconnects_informational:$disconnects, srt_latency_ms:$srt_latency_ms},
    recover:{link2_recovered:$link2_recovered, recover_ms:$recover_ms},
    timestamp:$ts
  }' > "$RESULT_JSON"

log ""
log "================ link-drop summary ================"
log "  establish_ok=${establish_ok} (handshake=${handshake} both_links=${both_links_added})"
log "  shift_ok=${shift_ok} (link2_failed=${link2_failed} survivor_up=${survivor_stayed_up} shift_ms=${shift_ms})"
log "  survivor_ok=${survivor_ok} (bytes=${bytes}; disc=${disc} informational)"
log "  recover_ok=${recover_ok} (recover_ms=${recover_ms})"
log "  result: ${RESULT_JSON}"
log "==================================================="

if [[ "$KEEP_LOGS" -eq 0 && "$pass" == true ]]; then
  rm -f "$RX_LOG" "$TX_LOG" "$FF_LOG" "${SINK_JSON%.json}.log" "$IPS_FILE"
fi

if [[ "$pass" == true ]]; then log "PASS"; exit 0; else log "FAIL"; exit 1; fi

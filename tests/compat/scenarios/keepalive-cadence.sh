#!/usr/bin/env bash
#
# keepalive-cadence.sh — D21 instrument: receiver recovery-keepalive cadence.
#
# Measures, from the SENDER's own log, whether decoupling srtla_rec's recovery/
# NAT keepalives from the cleanup throttle (every KEEPALIVE_PERIOD instead of
# every CLEANUP_PERIOD) helps the sender keep and recover a bonded uplink.
#
# Topology (two loopback source IPs; 127.0.0.0/8 is all local on Linux, so no
# address alias is needed — only netfilter access to isolate one link):
#
#   ffmpeg(SRT caller) -> srtla_send --[127.0.0.1]--> srtla_rec -> srt-sink
#                                    \--[127.0.0.2]--/
#
# The impaired uplink is the SECOND entry of BIND_IPS_FILE (index 1), matching
# the metric contract in tests/compat/lib/sender-log-metrics.py.
#
# Scenarios (selected by the group's `impairment` env knob):
#   S1 blackhole-bidirectional   both directions on uplink-1 dropped for 10 s
#   S2 receiver-sigterm-restart  srtla_rec SIGTERM'd and restarted within 2 s
#   S3 blackhole-inbound-only    receiver -> sender on uplink-1 dropped for 4 s
#
# Every run lasts --duration seconds (default 60) and the impairment begins at
# $IMPAIRMENT_START_S seconds (default 20) measured against the sender's FIRST
# log timestamp, so the millisecond offsets the metrics parser computes line up
# exactly with the pre-registered windows.
#
# Blocks until the receiver comes up and the topology establishes before the
# impairment clock starts, so a slow build/startup never eats into the 20 s.
#
# Usage:
#   keepalive-cadence.sh [--build-dir DIR] [--duration SEC] [--keep-logs] [-h]
#
# Environment (set by ab-campaign.sh from the scenario document):
#   impairment           blackhole-bidirectional | receiver-sigterm-restart |
#                        blackhole-inbound-only         (required)
#   duration_s           impairment duration in seconds (blackhole scenarios)
#   restart_within_s     receiver restart bound in seconds (S2; default 2)
#   target               impairment target label, echoed into result.json
#   SRTLA_SEND_RS_BIN    the Rust sender under test (required; REQUIRE_RS_SENDER
#                        makes its absence a SKIP rather than a C-sender run)
#   SRTLA_REC_BIN        receiver binary (arm A = build dir's srtla_rec, arm B =
#                        the patched scratch build); defaults to build/srtla_rec
#   SRTLA_BUILD_DIR      base build dir (needs srtla_rec + srt-sink)
#
# Artifacts land in tests/compat/results/keepalive-cadence/ (gitignored);
# result.json carries every parameter the metrics parser needs.
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." >/dev/null 2>&1 && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../results/keepalive-cadence"

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'keepalive-cadence: %s\n' "$*" >&2; exit 2; }
now_ms() { date +%s%3N; }

BUILD_DIR="${SRTLA_BUILD_DIR:-}"
KEEP_LOGS=0
DURATION=60
IMPAIRMENT_START_S="${IMPAIRMENT_START_S:-20}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir) BUILD_DIR="${2:?--build-dir needs a value}"; shift 2 ;;
    --duration)  DURATION="${2:?--duration needs a value}"; shift 2 ;;
    --keep-logs) KEEP_LOGS=1; shift ;;
    -h|--help)   sed -n '2,54p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown argument '$1' (try --help)" ;;
  esac
done

[[ "$DURATION" =~ ^[0-9]+$ && "$DURATION" -ge 5 ]] || die "--duration must be an integer >= 5"
[[ "$IMPAIRMENT_START_S" =~ ^[0-9]+$ ]] || die "IMPAIRMENT_START_S must be an integer"

IMPAIRMENT="${impairment:-}"
[[ -n "$IMPAIRMENT" ]] || die "no 'impairment' env knob (set by ab-campaign.sh from the group)"
TARGET="${target:-uplink-1}"
RESTART_WITHIN_S="${restart_within_s:-2}"
PATCH_ID="${patch:-}"

for tool in ffmpeg jq python3; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' not found in PATH"
done

# iptables capability gate — SKIP (exit 3) if we cannot manipulate the firewall.
IPT=""
if iptables -S OUTPUT >/dev/null 2>&1; then
  IPT="iptables"
elif sudo -n iptables -S OUTPUT >/dev/null 2>&1; then
  IPT="sudo -n iptables"
fi
if [[ -z "$IPT" ]]; then
  log "SKIP keepalive-cadence: no iptables access (needs root/sudo to isolate a link)"
  mkdir -p "$RESULTS_DIR"
  printf '{"scenario":"keepalive-cadence","skipped":true,"reason":"no iptables access"}\n' \
    > "${RESULTS_DIR}/result.json"
  exit 3
fi

resolve_build_dir() {
  local candidates=()
  [[ -n "$BUILD_DIR" ]] && candidates+=("$BUILD_DIR")
  candidates+=("${REPO_ROOT}/build" "/tmp/srtla-build")
  local d
  for d in "${candidates[@]}"; do
    if [[ -x "${d}/srtla_rec" && -x "${d}/tests/compat/srt-sink/srt-sink" ]]; then
      printf '%s' "$d"; return 0
    fi
  done
  return 1
}
BUILD_DIR="$(resolve_build_dir)" || die \
  "no usable build dir (need srtla_rec, tests/compat/srt-sink/srt-sink). Build with:
   cmake -B build -DBUILD_COMPAT_TESTS=ON && cmake --build build -j"

SRT_SINK="${BUILD_DIR}/tests/compat/srt-sink/srt-sink"
SRTLA_REC="${SRTLA_REC_BIN:-${BUILD_DIR}/srtla_rec}"
[[ -x "$SRTLA_REC" ]] || die "receiver binary '$SRTLA_REC' is not executable"

SRTLA_SEND_RS_BIN="${SRTLA_SEND_RS_BIN:-}"
REQUIRE_RS_SENDER="${REQUIRE_RS_SENDER:-}"
SENDER_BIN=""
if [[ -n "$SRTLA_SEND_RS_BIN" ]]; then
  [[ -x "$SRTLA_SEND_RS_BIN" ]] || die "SRTLA_SEND_RS_BIN '$SRTLA_SEND_RS_BIN' is not executable"
  SENDER_BIN="$SRTLA_SEND_RS_BIN"
elif [[ "$REQUIRE_RS_SENDER" == "1" ]]; then
  log "SKIP keepalive-cadence: REQUIRE_RS_SENDER=1 but SRTLA_SEND_RS_BIN is unset"
  mkdir -p "$RESULTS_DIR"
  printf '{"scenario":"keepalive-cadence","skipped":true,"reason":"no Rust sender"}\n' \
    > "${RESULTS_DIR}/result.json"
  exit 3
else
  die "SRTLA_SEND_RS_BIN is required (set by ab-campaign.sh)"
fi

# Two bonded source IPs on loopback; receiver + sink stay on 127.0.0.1.
UPLINK0_IP=127.0.0.1
UPLINK1_IP=127.0.0.2   # impaired uplink = BIND_IPS_FILE index 1
RECV_IP=127.0.0.1
SRTLA_PORT=5501
SINK_PORT=4501
LOCAL_SRT_PORT=6501

SRT_LATENCY_MS=4000
MIN_BYTES=50000

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

restore_rules() {
  [[ "$DROP_RULES_ACTIVE" -eq 1 ]] || return 0
  $IPT -D OUTPUT -s "$UPLINK1_IP" -d "$RECV_IP" -p udp -j DROP 2>/dev/null || true
  $IPT -D OUTPUT -s "$RECV_IP" -d "$UPLINK1_IP" -p udp -j DROP 2>/dev/null || true
  DROP_RULES_ACTIVE=0
}
cleanup() {
  restore_rules
  local p
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill -TERM "$p" 2>/dev/null; done
}
trap cleanup EXIT INT TERM

stop_pid() { local pid="$1"; [[ -n "$pid" ]] || return 0; kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }

# Bounded TERM->KILL for the receiver (S2); never waits forever on a stuck rec.
stop_receiver() {
  local pid="$1" deadline
  [[ -n "$pid" ]] || return 0
  kill -TERM "$pid" 2>/dev/null || return 0
  deadline=$(( $(now_ms) + 1500 ))
  while [[ "$(now_ms)" -lt "$deadline" ]]; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return 0; }
    sleep 0.05
  done
  log "receiver $pid ignored SIGTERM; sending SIGKILL"
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

wait_for_marker() { # logfile marker timeout_s -> 0 if seen
  local f="$1" m="$2" deadline=$(( $(now_ms) + ${3} * 1000 ))
  while [[ "$(now_ms)" -lt "$deadline" ]]; do
    grep -q -- "$m" "$f" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}

sleep_until() { # epoch_ms -> return once wall clock reaches it
  local target="$1" now d guard
  guard=$(( $(now_ms) + 300000 ))
  while :; do
    now=$(now_ms)
    (( now >= target )) && return 0
    (( now >= guard )) && die "sleep_until: clock alignment failed (target=${target} now=${now})"
    d=$(( target - now ))
    if (( d > 200 )); then sleep 0.05; else sleep 0.01; fi
  done
}

# Epoch ms of the first timestamped line (the sender's startup line). tracing
# emits ANSI codes even to a file, so strip them before anchoring the match.
log_t0_ms() {
  python3 - "$1" <<'PY'
import re, sys
from datetime import datetime, timezone
ansi = re.compile(r"\x1b\[[0-9;]*m")
rx = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+)Z?")
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    m = rx.match(ansi.sub("", line))
    if m:
        stamp = datetime.fromisoformat(m.group(1)).replace(tzinfo=timezone.utc)
        print(int(stamp.timestamp() * 1000))
        break
PY
}

# ----------------------------------------------------------------------------- #
# Stream topology.                                                              #
# ----------------------------------------------------------------------------- #
"$SRT_SINK" --port "$SINK_PORT" --host "$RECV_IP" --result "$SINK_JSON" \
            --latency "$SRT_LATENCY_MS" \
            --duration $(( DURATION + 40 )) \
            >"${SINK_JSON%.json}.log" 2>&1 &
SINK_PID=$!; track "$SINK_PID"
sleep 0.5

start_receiver() {
  "$SRTLA_REC" --srtla_port "$SRTLA_PORT" --srt_hostname "$RECV_IP" \
               --srt_port "$SINK_PORT" --log_level trace >>"$RX_LOG" 2>&1 &
  RX_PID=$!; track "$RX_PID"
}
start_receiver
wait_for_marker "$RX_LOG" "srtla_rec is now running" 5 || die "receiver never came up"

printf '%s\n%s\n' "$UPLINK0_IP" "$UPLINK1_IP" > "$IPS_FILE"

# --verbose forces debug so REG3/selection markers are present; sender-log-metrics
# marks a run invalid without them.
"$SENDER_BIN" "$LOCAL_SRT_PORT" "$RECV_IP" "$SRTLA_PORT" "$IPS_FILE" --verbose \
  >"$TX_LOG" 2>&1 &
TX_PID=$!; track "$TX_PID"
SEND_START_MS=$(now_ms)

sleep 0.6

# The SRT caller must ride through a multi-second link transition (deep buffer +
# generous I/O timeout), exactly as link-drop.sh does. ffmpeg SRT times are µs.
SRT_LATENCY_US=$(( SRT_LATENCY_MS * 1000 ))
SRT_OPTS="mode=caller&transtype=live&latency=${SRT_LATENCY_US}&peerlatency=${SRT_LATENCY_US}&sndbuf=24000000&timeout=30000000"
ffmpeg -hide_banner -loglevel warning -re \
  -f lavfi -i testsrc2=size=320x240:rate=25 -c:v mpeg2video -b:v 700k -f mpegts \
  "srt://127.0.0.1:${LOCAL_SRT_PORT}?${SRT_OPTS}" \
  >"$FF_LOG" 2>&1 &
FF_PID=$!; track "$FF_PID"

handshake=false
wait_for_marker "$RX_LOG" "Group registered" 10 && handshake=true
log "handshake=${handshake} (impairment=${IMPAIRMENT} target=${TARGET})"

# Align the impairment clock to the sender log's first timestamp.
LOG_T0_MS=""
for _ in $(seq 1 50); do
  LOG_T0_MS="$(log_t0_ms "$TX_LOG" 2>/dev/null || true)"
  [[ -n "$LOG_T0_MS" ]] && break
  sleep 0.1
done
if [[ -z "$LOG_T0_MS" ]]; then
  LOG_T0_MS="$SEND_START_MS"
  log "WARN no sender log timestamp yet; falling back to process start for alignment"
fi
log "sender log t0 epoch_ms=${LOG_T0_MS}"

IMPAIRMENT_START_MS=$(( IMPAIRMENT_START_S * 1000 ))

# ----------------------------------------------------------------------------- #
# Impairment.                                                                   #
# ----------------------------------------------------------------------------- #
IMPAIRMENT_DURATION_S="${duration_s:-0}"
[[ "$IMPAIRMENT_DURATION_S" =~ ^[0-9]+$ ]] || IMPAIRMENT_DURATION_S=0

apply_bidirectional() {
  $IPT -I OUTPUT -s "$UPLINK1_IP" -d "$RECV_IP" -p udp -j DROP 2>/dev/null || true
  $IPT -I OUTPUT -s "$RECV_IP" -d "$UPLINK1_IP" -p udp -j DROP 2>/dev/null || true
  DROP_RULES_ACTIVE=1
}
apply_inbound_only() {
  $IPT -I OUTPUT -s "$RECV_IP" -d "$UPLINK1_IP" -p udp -j DROP 2>/dev/null || true
  DROP_RULES_ACTIVE=1
}

RECEIVER_RESTART_MS=-1
sleep_until $(( LOG_T0_MS + IMPAIRMENT_START_MS ))
IMPAIR_T0_MS=$(now_ms)
log "==> impairment starts (t=${IMPAIRMENT_START_S}s): ${IMPAIRMENT}"

case "$IMPAIRMENT" in
  blackhole-bidirectional)
    apply_bidirectional
    sleep_until $(( IMPAIR_T0_MS + IMPAIRMENT_DURATION_S * 1000 ))
    restore_rules
    ;;
  blackhole-inbound-only)
    apply_inbound_only
    sleep_until $(( IMPAIR_T0_MS + IMPAIRMENT_DURATION_S * 1000 ))
    restore_rules
    ;;
  receiver-sigterm-restart)
    stop_receiver "$RX_PID"
    start_receiver
    RECEIVER_RESTART_MS=$(( $(now_ms) - IMPAIR_T0_MS ))
    log "==> receiver restarted in ${RECEIVER_RESTART_MS} ms (bound ${RESTART_WITHIN_S}s)"
    ;;
  *)
    die "unknown impairment '$IMPAIRMENT'"
    ;;
esac

# The frozen metric's impairment window is the SPEC bound for S2 (start + the
# declared restart bound), so run-to-run restart jitter cannot move the window.
case "$IMPAIRMENT" in
  blackhole-*)             IMPAIRMENT_END_MS=$(( IMPAIRMENT_START_MS + IMPAIRMENT_DURATION_S * 1000 )) ;;
  receiver-sigterm-restart) IMPAIRMENT_END_MS=$(( IMPAIRMENT_START_MS + RESTART_WITHIN_S * 1000 )) ;;
  *)                        IMPAIRMENT_END_MS=$(( IMPAIRMENT_START_MS + IMPAIRMENT_DURATION_S * 1000 )) ;;
esac

# ----------------------------------------------------------------------------- #
# Run out the full duration so the t=<duration> status report lands in the log.  #
# ----------------------------------------------------------------------------- #
sleep_until $(( LOG_T0_MS + DURATION * 1000 + 800 ))

# Teardown: sink FIRST so the intentional ffmpeg/sender stop is not a mid-stream
# disconnect (the sink only tallies a break while it is still running).
stop_pid "$SINK_PID"
[[ -n "${FF_PID:-}" ]] && { kill -TERM "$FF_PID" 2>/dev/null; wait "$FF_PID" 2>/dev/null; }
stop_pid "$TX_PID"
[[ -n "${RX_PID:-}" ]] && stop_pid "$RX_PID"
restore_rules

bytes="$(jq -r '.bytes_received // 0' "$SINK_JSON" 2>/dev/null || echo 0)"
[[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0

pass=false
[[ "$handshake" == true && "$bytes" -ge "$MIN_BYTES" ]] && pass=true

jq -n \
  --arg scenario "keepalive-cadence" \
  --arg impairment "$IMPAIRMENT" \
  --arg target "$TARGET" \
  --arg sender_log "$TX_LOG" \
  --arg receiver_bin "$SRTLA_REC" \
  --arg receiver_patch "$PATCH_ID" \
  --arg profile "$PROFILE_LABEL" \
  --argjson uplink_index 1 \
  --arg uplink_label "$UPLINK1_IP" \
  --argjson impairment_start_ms "$IMPAIRMENT_START_MS" \
  --argjson impairment_end_ms "$IMPAIRMENT_END_MS" \
  --argjson duration_ms $(( DURATION * 1000 )) \
  --argjson impairment_start_epoch_ms "$IMPAIR_T0_MS" \
  --argjson sender_log_t0_epoch_ms "$LOG_T0_MS" \
  --argjson receiver_restart_ms "$RECEIVER_RESTART_MS" \
  --argjson handshake "$handshake" \
  --argjson pass "$pass" \
  --argjson bytes "$bytes" \
  --argjson min_bytes "$MIN_BYTES" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    scenario:$scenario,
    impairment:$impairment,
    target:$target,
    sender_log:$sender_log,
    receiver_bin:$receiver_bin,
    receiver_patch:$receiver_patch,
    profile:$profile,
    uplink_index:$uplink_index,
    uplink_label:$uplink_label,
    impairment_start_ms:$impairment_start_ms,
    impairment_end_ms:$impairment_end_ms,
    duration_ms:$duration_ms,
    impairment_start_epoch_ms:$impairment_start_epoch_ms,
    sender_log_t0_epoch_ms:$sender_log_t0_epoch_ms,
    receiver_restart_ms:$receiver_restart_ms,
    handshake:$handshake,
    pass:$pass,
    sink:{bytes_received:$bytes, min_bytes:$min_bytes},
    timestamp:$ts
  }' > "$RESULT_JSON"

log "keepalive-cadence: impairment=${IMPAIRMENT} handshake=${handshake} pass=${pass} bytes=${bytes}"
log "result: ${RESULT_JSON}"

if [[ "$KEEP_LOGS" -eq 0 && "$pass" == true ]]; then
  rm -f "$RX_LOG" "$TX_LOG" "$FF_LOG" "${SINK_JSON%.json}.log" "$IPS_FILE"
fi

if [[ "$handshake" == true ]]; then exit 0; else exit 1; fi

#!/usr/bin/env bash
#
# replay.sh — replay a captured SRTLA session against a live local srtla_rec.
#
# Stands up a throwaway receiver pipeline:
#
#     replay.py replay <pcap> --SRTLA--> srtla_rec --UDP--> replay.py sink
#
# and asserts, against the running binary (not just code reading), that:
#
#   1. SRTLA registration completes        (receiver log: "Group registered")
#   2. >= MIN_PACKETS datagrams forwarded  (downstream UDP sink count)
#   3. the receiver is still alive          (process up at end of replay)
#
# The replay is handshake-aware (see replay.py) so a fresh receiver's
# per-session group nonce does not reject the captured registration.
#
# Fixture policy (CI-friendly): if the pcap is absent the test SKIPs with
# exit code 77 — it never blocks CI on a fixture that lives in git-LFS and
# may not be pulled. Provide one by following ../CAPTURE.md.
#
# Usage:
#   replay.sh [<pcap>] [options]
#
# Options:
#   --build-dir <dir>   Directory holding srtla_rec (else autodetected).
#   --min-packets <n>   Delivered-packet threshold (default 500).
#   --speed <x>         Replay timing multiplier passed to replay.py (default 4).
#   --keep-logs         Keep the run log dir even on PASS.
#   -h, --help          This help.
#
# Environment:
#   SRTLA_BUILD_DIR     Same as --build-dir.
#
# Exit codes: 0 PASS · 1 FAIL · 77 SKIP (fixture absent) · 2 setup error.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
COMPAT_DIR="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${COMPAT_DIR}/../.." >/dev/null 2>&1 && pwd)"
REPLAY_PY="${SCRIPT_DIR}/replay.py"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'replay.sh: %s\n' "$*" >&2; exit 2; }

# --------------------------------------------------------------------------- #
# CLI                                                                          #
# --------------------------------------------------------------------------- #
PCAP="${COMPAT_DIR}/fixtures/real-moblin.pcap"
BUILD_DIR="${SRTLA_BUILD_DIR:-}"
MIN_PACKETS=500
SPEED=4
KEEP_LOGS=0
pcap_set=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir)   BUILD_DIR="${2:?--build-dir needs a value}"; shift 2 ;;
    --min-packets) MIN_PACKETS="${2:?--min-packets needs a value}"; shift 2 ;;
    --speed)       SPEED="${2:?--speed needs a value}"; shift 2 ;;
    --keep-logs)   KEEP_LOGS=1; shift ;;
    -h|--help)     sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --*)           die "unknown option '$1' (try --help)" ;;
    *)             PCAP="$1"; pcap_set=1; shift ;;
  esac
done

[[ "$MIN_PACKETS" =~ ^[0-9]+$ ]] || die "--min-packets must be an integer"
command -v python3 >/dev/null 2>&1 || die "python3 not found in PATH"
[[ -f "$REPLAY_PY" ]] || die "replay.py not found next to this script"

# --------------------------------------------------------------------------- #
# Fixture gate — SKIP (77) when absent so CI never blocks on a missing pcap.   #
# --------------------------------------------------------------------------- #
if [[ ! -s "$PCAP" ]]; then
  log "fixture absent — skipping: ${PCAP}"
  log "  (provide one via ${COMPAT_DIR}/CAPTURE.md, then re-run)"
  exit 77
fi

# --------------------------------------------------------------------------- #
# Resolve srtla_rec.                                                           #
# --------------------------------------------------------------------------- #
resolve_build_dir() {
  local candidates=() d
  [[ -n "$BUILD_DIR" ]] && candidates+=("$BUILD_DIR")
  candidates+=("${REPO_ROOT}/build" "/tmp/srtla-build")
  for d in "${candidates[@]}"; do
    [[ -x "${d}/srtla_rec" ]] && { printf '%s' "$d"; return 0; }
  done
  return 1
}
BUILD_DIR="$(resolve_build_dir)" || die \
  "srtla_rec not found. Build with: cmake -B build && cmake --build build -j
   (or pass --build-dir <dir> / set SRTLA_BUILD_DIR)."
SRTLA_REC="${BUILD_DIR}/srtla_rec"

# --------------------------------------------------------------------------- #
# Run scaffolding.                                                             #
# --------------------------------------------------------------------------- #
SRTLA_PORT=5301
SINK_PORT=4301
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/srtla-replay.XXXXXX")"
REC_LOG="${RUN_DIR}/receiver.log"
SINK_LOG="${RUN_DIR}/sink.log"
REPLAY_LOG="${RUN_DIR}/replay.log"
COUNT_FILE="${RUN_DIR}/sink.count"

REC_PID=""; SINK_PID=""
cleanup() {
  [[ -n "$REC_PID"  ]] && kill -TERM "$REC_PID"  2>/dev/null
  [[ -n "$SINK_PID" ]] && kill -TERM "$SINK_PID" 2>/dev/null
  wait 2>/dev/null
  if [[ "$KEEP_LOGS" -eq 0 && "${PASS:-0}" -eq 1 ]]; then rm -rf "$RUN_DIR"; fi
}
trap cleanup EXIT INT TERM

log "==> pcap-replay  pcap=${PCAP##*/}  min_packets=${MIN_PACKETS}  speed=${SPEED}"

# 1) downstream UDP sink — bind first so srtla_rec's connect() succeeds.
python3 "$REPLAY_PY" sink --host 127.0.0.1 --port "$SINK_PORT" \
        --count-file "$COUNT_FILE" --idle 5 --duration 180 \
        >"$SINK_LOG" 2>&1 &
SINK_PID=$!
sleep 0.3

# 2) receiver.
"$SRTLA_REC" --srtla_port "$SRTLA_PORT" --srt_hostname 127.0.0.1 \
             --srt_port "$SINK_PORT" --log_level trace >"$REC_LOG" 2>&1 &
REC_PID=$!

rdy=0
for _ in $(seq 1 50); do
  grep -q "srtla_rec is now running" "$REC_LOG" 2>/dev/null && { rdy=1; break; }
  kill -0 "$REC_PID" 2>/dev/null || break
  sleep 0.1
done
[[ "$rdy" == 1 ]] || { log "    receiver failed to start"; cat "$REC_LOG" >&2; PASS=0; exit 1; }

# 3) replay the capture.
python3 "$REPLAY_PY" replay "$PCAP" --host 127.0.0.1 --port "$SRTLA_PORT" \
        --speed "$SPEED" >"$REPLAY_LOG" 2>&1
replay_rc=$?

# Let the receiver drain forwarded datagrams into the sink.
sleep 1

# 4) liveness — must be checked while the receiver is still up.
receiver_alive=0
kill -0 "$REC_PID" 2>/dev/null && receiver_alive=1

# 5) stop the sink so it flushes its final count, then collect metrics.
kill -TERM "$SINK_PID" 2>/dev/null; wait "$SINK_PID" 2>/dev/null; SINK_PID=""

registered=0
grep -q "Group registered" "$REC_LOG" 2>/dev/null && registered=1

delivered=0
[[ -f "$COUNT_FILE" ]] && delivered="$(tr -d '[:space:]' < "$COUNT_FILE")"
[[ "$delivered" =~ ^[0-9]+$ ]] || delivered=0

# --------------------------------------------------------------------------- #
# Verdict.                                                                     #
# --------------------------------------------------------------------------- #
reg_ok=false; pkts_ok=false; alive_ok=false
[[ "$registered" -eq 1 ]] && reg_ok=true
[[ "$delivered" -ge "$MIN_PACKETS" ]] && pkts_ok=true
[[ "$receiver_alive" -eq 1 ]] && alive_ok=true

log "    replay_rc=${replay_rc}  registered=${reg_ok}  delivered=${delivered}(>=${MIN_PACKETS}? ${pkts_ok})  receiver_alive=${alive_ok}"
log "    $(tail -n1 "$REPLAY_LOG" 2>/dev/null)"

if [[ "$reg_ok" == true && "$pkts_ok" == true && "$alive_ok" == true ]]; then
  PASS=1
  log "    PASS"
  exit 0
fi

PASS=0
log "    FAIL  (logs in ${RUN_DIR})"
KEEP_LOGS=1
exit 1

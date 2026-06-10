#!/usr/bin/env bash
#
# receiver-restart.sh — SRTLA receiver crash/restart re-registration scenario.
#
# Falsifiable counterpart to the descriptive BELABOX baseline in
# tests/compat/SMOKE_BASELINE.md (Phase B). It proves that OUR srtla_send
# recovers when srtla_rec is SIGKILLed mid-stream and a fresh receiver (empty
# group table) takes its place: the sender's stale connections time out, the
# fresh receiver answers their REG2 with REG_NGP, the sender re-issues REG1, a
# new group registers, and media resumes end-to-end — all within 30 s. The
# stock BELABOX sender did NOT re-register inside that window (baseline).
#
# Topology (single loopback link; no sudo, no loopback alias required):
#
#   ffmpeg(SRT caller) -> srtla_send -> srtla_rec -> srt-sink(SRT listener)
#
# Phase 1 establishes a stream to sink A. The receiver is killed and a fresh one
# is started pointing at sink B; the still-running sender must re-register within
# RE_REGISTER_DEADLINE and push >= MIN_BYTES to sink B.
#
# PASS <=> phase-1 handshake + bytes AND re-registration + resumed bytes <= 30 s.
#
# Usage:
#   receiver-restart.sh [--build-dir DIR] [--keep-logs] [-h]
#
# Artifacts land in tests/compat/results/receiver-restart/ (gitignored); nothing
# is written outside the repo (Rule D).
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." >/dev/null 2>&1 && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../results/receiver-restart"

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'receiver-restart: %s\n' "$*" >&2; exit 2; }
now_ms() { date +%s%3N; }

BUILD_DIR="${SRTLA_BUILD_DIR:-}"
KEEP_LOGS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir) BUILD_DIR="${2:?--build-dir needs a value}"; shift 2 ;;
    --keep-logs) KEEP_LOGS=1; shift ;;
    -h|--help)   sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# Distinct ports per role; sink A/B isolate pre- and post-restart byte counts.
SRTLA_PORT=5201
SINK_A_PORT=4201
SINK_B_PORT=4202
LOCAL_SRT_PORT=6201

MIN_BYTES=1000
RE_REGISTER_DEADLINE=30   # seconds, the scenario's headline bound
PHASE1_STREAM_SEC=10
RESUME_STREAM_SEC=10

rm -rf "$RESULTS_DIR"; mkdir -p "$RESULTS_DIR"
RX1_LOG="${RESULTS_DIR}/receiver-1.log"
RX2_LOG="${RESULTS_DIR}/receiver-2.log"
TX_LOG="${RESULTS_DIR}/sender.log"
FF1_LOG="${RESULTS_DIR}/ffmpeg-1.log"
FF2_LOG="${RESULTS_DIR}/ffmpeg-2.log"
SINK_A_JSON="${RESULTS_DIR}/sink-a.json"
SINK_B_JSON="${RESULTS_DIR}/sink-b.json"
IPS_FILE="${RESULTS_DIR}/ips.txt"
RESULT_JSON="${RESULTS_DIR}/result.json"

PIDS=()
track() { PIDS+=("$1"); }
cleanup() { local p; for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill -TERM "$p" 2>/dev/null; done; }
trap cleanup EXIT INT TERM

stop_pid() { local pid="$1" sig="${2:-TERM}"; [[ -n "$pid" ]] || return 0; kill -"$sig" "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }

# Start srt-sink in the MAIN shell (never via $(...) — a command-substitution
# subshell would reparent it, so the main shell's wait could not block on the
# JSON flush, and byte counts would read back as 0). Sets SINK_PID globally.
start_sink() {
  "$SRT_SINK" --port "$1" --host 127.0.0.1 --result "$2" --duration 60 \
    >"${2%.json}.log" 2>&1 &
  SINK_PID=$!
}

wait_for_marker() { # logfile marker timeout_s -> 0 if seen
  local f="$1" m="$2" deadline=$(( $(now_ms) + ${3} * 1000 ))
  while [[ "$(now_ms)" -lt "$deadline" ]]; do
    grep -q -- "$m" "$f" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}

sink_bytes() { jq -r '.bytes_received // 0' "$1" 2>/dev/null || echo 0; }

printf '127.0.0.1\n' > "$IPS_FILE"

# ----------------------------------------------------------------------------- #
# Phase 1 — establish a bonded stream to sink A.                                 #
# ----------------------------------------------------------------------------- #
log "==> phase 1: establish stream (build dir: ${BUILD_DIR})"

start_sink "$SINK_A_PORT" "$SINK_A_JSON"; SINK_A_PID="$SINK_PID"; track "$SINK_A_PID"
sleep 0.5

"$SRTLA_REC" --srtla_port "$SRTLA_PORT" --srt_hostname 127.0.0.1 \
             --srt_port "$SINK_A_PORT" --log_level trace >"$RX1_LOG" 2>&1 &
RX1_PID=$!; track "$RX1_PID"
wait_for_marker "$RX1_LOG" "srtla_rec is now running" 5 || die "receiver 1 never came up"

"$SRTLA_SEND" "$LOCAL_SRT_PORT" 127.0.0.1 "$SRTLA_PORT" "$IPS_FILE" >"$TX_LOG" 2>&1 &
TX_PID=$!; track "$TX_PID"
sleep 0.6

ffmpeg -hide_banner -loglevel warning -re \
  -f lavfi -i testsrc2=size=320x240:rate=25 -c:v mpeg2video -b:v 1M -f mpegts \
  "srt://127.0.0.1:${LOCAL_SRT_PORT}?mode=caller&transtype=live" >"$FF1_LOG" 2>&1 &
FF1_PID=$!; track "$FF1_PID"

phase1_handshake=false
wait_for_marker "$RX1_LOG" "Group registered" 10 && phase1_handshake=true
sleep "$PHASE1_STREAM_SEC"

stop_pid "$SINK_A_PID"
SINK_A_BYTES="$(sink_bytes "$SINK_A_JSON")"
[[ "$SINK_A_BYTES" =~ ^[0-9]+$ ]] || SINK_A_BYTES=0
log "    phase 1: handshake=${phase1_handshake} sink_a_bytes=${SINK_A_BYTES}"

# ----------------------------------------------------------------------------- #
# Phase 2 — crash the receiver, bring up a fresh one on sink B.                  #
# ----------------------------------------------------------------------------- #
log "==> phase 2: SIGKILL receiver, start a fresh receiver"
[[ -n "$FF1_PID" ]] && { kill -TERM "$FF1_PID" 2>/dev/null; wait "$FF1_PID" 2>/dev/null; }
kill -KILL "$RX1_PID" 2>/dev/null; wait "$RX1_PID" 2>/dev/null

RESTART_T0="$(now_ms)"
start_sink "$SINK_B_PORT" "$SINK_B_JSON"; SINK_B_PID="$SINK_PID"; track "$SINK_B_PID"

# Fresh receiver, empty group table, pointing at sink B.
"$SRTLA_REC" --srtla_port "$SRTLA_PORT" --srt_hostname 127.0.0.1 \
             --srt_port "$SINK_B_PORT" --log_level trace >"$RX2_LOG" 2>&1 &
RX2_PID=$!; track "$RX2_PID"
wait_for_marker "$RX2_LOG" "srtla_rec is now running" 5 || die "receiver 2 never came up"

# ----------------------------------------------------------------------------- #
# Phase 3 — the still-running sender must re-register within the deadline.       #
# ----------------------------------------------------------------------------- #
log "==> phase 3: await sender re-registration (<= ${RE_REGISTER_DEADLINE}s)"
re_registered=false
if wait_for_marker "$RX2_LOG" "Group registered" "$RE_REGISTER_DEADLINE"; then
  re_registered=true
fi
REREG_MS=$(( $(now_ms) - RESTART_T0 ))

# The fresh receiver rejects the sender's stale REG2 with REG_NGP ("No group
# found") before the re-REG1; record that the NGP retry path actually fired.
ngp_observed=false
grep -q "No group found" "$RX2_LOG" 2>/dev/null && ngp_observed=true

# Now confirm media resumes through the re-registered group.
resumed_bytes=0
if [[ "$re_registered" == true ]]; then
  ffmpeg -hide_banner -loglevel warning -re \
    -f lavfi -i testsrc2=size=320x240:rate=25 -c:v mpeg2video -b:v 1M -f mpegts \
    "srt://127.0.0.1:${LOCAL_SRT_PORT}?mode=caller&transtype=live" >"$FF2_LOG" 2>&1 &
  FF2_PID=$!; track "$FF2_PID"
  sleep "$RESUME_STREAM_SEC"
  [[ -n "${FF2_PID:-}" ]] && { kill -TERM "$FF2_PID" 2>/dev/null; wait "$FF2_PID" 2>/dev/null; }
fi

stop_pid "$SINK_B_PID"
resumed_bytes="$(sink_bytes "$SINK_B_JSON")"
[[ "$resumed_bytes" =~ ^[0-9]+$ ]] || resumed_bytes=0

stop_pid "$TX_PID"
stop_pid "$RX2_PID"

# ----------------------------------------------------------------------------- #
# Verdict.                                                                       #
# ----------------------------------------------------------------------------- #
phase1_ok=false
[[ "$phase1_handshake" == true && "$SINK_A_BYTES" -ge "$MIN_BYTES" ]] && phase1_ok=true

reregister_ok=false
[[ "$re_registered" == true && "$REREG_MS" -le $(( RE_REGISTER_DEADLINE * 1000 )) ]] && reregister_ok=true

resume_ok=false
[[ "$resumed_bytes" -ge "$MIN_BYTES" ]] && resume_ok=true

pass=false
[[ "$phase1_ok" == true && "$reregister_ok" == true && "$resume_ok" == true ]] && pass=true

jq -n \
  --argjson pass "$pass" \
  --argjson phase1_ok "$phase1_ok" \
  --argjson reregister_ok "$reregister_ok" \
  --argjson resume_ok "$resume_ok" \
  --argjson sink_a_bytes "$SINK_A_BYTES" \
  --argjson resumed_bytes "$resumed_bytes" \
  --argjson reregister_ms "$REREG_MS" \
  --argjson deadline_ms $(( RE_REGISTER_DEADLINE * 1000 )) \
  --argjson ngp_observed "$ngp_observed" \
  --arg baseline "BELABOX srtla_send did NOT re-register within 30s (SMOKE_BASELINE.md Phase B)" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    scenario:"receiver-restart", pass:$pass,
    criteria:{phase1_ok:$phase1_ok, reregister_ok:$reregister_ok, resume_ok:$resume_ok},
    phase1:{sink_a_bytes:$sink_a_bytes, min_bytes:1000},
    restart:{reregister_ms:$reregister_ms, deadline_ms:$deadline_ms,
             ngp_retry_observed:$ngp_observed, resumed_bytes:$resumed_bytes},
    comparison:{ours:"re-registers and resumes", belabox_baseline:$baseline},
    timestamp:$ts
  }' > "$RESULT_JSON"

log ""
log "================ receiver-restart summary ================"
log "  phase1_ok=${phase1_ok} (sink_a_bytes=${SINK_A_BYTES})"
log "  reregister_ok=${reregister_ok} (reregister_ms=${REREG_MS}, ngp_retry=${ngp_observed})"
log "  resume_ok=${resume_ok} (resumed_bytes=${resumed_bytes})"
log "  vs BELABOX baseline: did NOT re-register in 30s (SMOKE_BASELINE.md Phase B)"
log "  result: ${RESULT_JSON}"
log "=========================================================="

if [[ "$KEEP_LOGS" -eq 0 && "$pass" == true ]]; then
  rm -f "$RX1_LOG" "$RX2_LOG" "$TX_LOG" "$FF1_LOG" "$FF2_LOG" \
        "${SINK_A_JSON%.json}.log" "${SINK_B_JSON%.json}.log" "$IPS_FILE"
fi

if [[ "$pass" == true ]]; then log "PASS"; exit 0; else log "FAIL"; exit 1; fi

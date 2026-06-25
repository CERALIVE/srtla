#!/usr/bin/env bash
#
# ts-continuity-loopback.sh — real-SRT loopback that proves srt-sink's MPEG-TS
# continuity metric (ts_cc_errors) is both correct on a clean stream and
# FALSIFIABLE on a damaged one.
#
# Two legs run an actual SRT caller -> srt-sink (SRT listener) transfer over
# 127.0.0.1 and read the metrics srt-sink writes to its --result JSON:
#
#   CLEAN   : a freshly-muxed MPEG-TS is sent raw (byte-faithful) -> the sink
#             must report ts_sync_errors == 0 AND ts_cc_errors == 0.
#   DROPPED : the SAME TS with exactly one payload-bearing TS packet excised
#             (a real continuity break) is sent raw -> the sink must report
#             ts_cc_errors > 0.
#
# WHY raw passthrough (srt-live-transmit), not ffmpeg: ffmpeg re-muxes the TS
# container even with `-c copy`, regenerating the continuity counters and so
# HEALING the injected drop. srt-live-transmit forwards the file bytes verbatim,
# preserving the discontinuity end-to-end. The payload is paced to ~real time
# (a small Python pacer) and zero-padded to a whole SRT chunk (with valid null
# TS packets, PID 0x1FFF) so the live socket neither drops "too-late" packets
# nor zero-pads a short final message into a spurious sync error.
#
# This is the integration-level companion to the hermetic unit test
# `ts-continuity-test` (ctest), which proves the same falsifiability against the
# parser directly with no network.
#
# Privilege: NONE. Requires srt-live-transmit (libsrt-tools); without it the
# scenario SKIPs cleanly (exit 3), like the other capability-gated scenarios.
#
# Usage:
#   ts-continuity-loopback.sh [--build-dir DIR] [--duration SEC] [--keep-logs] [-h]
#     --duration SEC   per-leg media length (default 6).
#
# Artifacts land in tests/compat/results/ts-continuity-loopback/ (gitignored);
# nothing is written outside the repo and no `../`-escaping path is used (Rule D).
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." >/dev/null 2>&1 && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../results/ts-continuity-loopback"

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'ts-continuity-loopback: %s\n' "$*" >&2; exit 2; }

# --------------------------------------------------------------------------- #
# CLI                                                                         #
# --------------------------------------------------------------------------- #
BUILD_DIR="${SRTLA_BUILD_DIR:-}"
KEEP_LOGS=0
MEDIA_SEC=6

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir) BUILD_DIR="${2:?--build-dir needs a value}"; shift 2 ;;
    --duration)  MEDIA_SEC="${2:?--duration needs a value}"; shift 2 ;;
    --keep-logs) KEEP_LOGS=1; shift ;;
    -h|--help)   sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown argument '$1' (try --help)" ;;
  esac
done
[[ "$MEDIA_SEC" =~ ^[0-9]+$ && "$MEDIA_SEC" -ge 1 ]] || die "--duration must be a positive integer"

# Core harness tools are hard requirements; srt-live-transmit is the gated
# capability this scenario SKIPs on (mirrors `requires:` in matrix.yaml).
for tool in ffmpeg jq python3; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' not found in PATH"
done
if ! command -v srt-live-transmit >/dev/null 2>&1; then
  log "SKIP ts-continuity-loopback: srt-live-transmit not found (install libsrt-tools)"
  mkdir -p "$RESULTS_DIR"
  printf '{"scenario":"ts-continuity-loopback","skipped":true,"reason":"srt-live-transmit not installed"}\n' \
    > "${RESULTS_DIR}/result.json"
  exit 3
fi

# --------------------------------------------------------------------------- #
# Resolve the srt-sink helper (built with -DBUILD_COMPAT_TESTS=ON).           #
# --------------------------------------------------------------------------- #
resolve_build_dir() {
  local candidates=()
  [[ -n "$BUILD_DIR" ]] && candidates+=("$BUILD_DIR")
  candidates+=("${REPO_ROOT}/build" "/tmp/srtla-build")
  local d
  for d in "${candidates[@]}"; do
    [[ -x "${d}/tests/compat/srt-sink/srt-sink" ]] && { printf '%s' "$d"; return 0; }
  done
  return 1
}
BUILD_DIR="$(resolve_build_dir)" || die \
  "srt-sink not found. Build with:
   cmake -B build -DBUILD_COMPAT_TESTS=ON && cmake --build build -j"
SRT_SINK="${BUILD_DIR}/tests/compat/srt-sink/srt-sink"

# --------------------------------------------------------------------------- #
# Constants / artifacts                                                       #
# --------------------------------------------------------------------------- #
SINK_PORT_CLEAN=4861
SINK_PORT_DROP=4862
SRT_LATENCY_MS=500
SINK_DURATION=$((MEDIA_SEC + 20))     # self-timeout guard, well past the send
TX_TIMEOUT=$((MEDIA_SEC + 12))        # hard cap on a hung srt-live-transmit
SLT_EXIT_SEC=$((MEDIA_SEC + 4))       # srt-live-transmit's own since-start timer

rm -rf "$RESULTS_DIR"; mkdir -p "$RESULTS_DIR"
CLEAN_TS="${RESULTS_DIR}/source.ts"
CLEAN_PAD_TS="${RESULTS_DIR}/clean.ts"
DROPPED_TS="${RESULTS_DIR}/dropped.ts"
PACER="${RESULTS_DIR}/pace.py"
BUILDER="${RESULTS_DIR}/build_ts.py"
CLEAN_JSON="${RESULTS_DIR}/clean.json"
DROP_JSON="${RESULTS_DIR}/dropped.json"
RESULT_JSON="${RESULTS_DIR}/result.json"

PIDS=()
cleanup() { local p; for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill -TERM "$p" 2>/dev/null; done; }
trap cleanup EXIT INT TERM

# --------------------------------------------------------------------------- #
# Helper scripts (kept in the gitignored results dir; Rule D).                 #
# --------------------------------------------------------------------------- #
# Pace a file to stdout over ~DUR seconds in 1316-byte (7x188) chunks so the SRT
# live socket sees a real-time stream instead of a loss-inducing burst.
cat > "$PACER" <<'PY'
import sys, time
CH = 1316
data = open(sys.argv[1], 'rb').read()
dur = float(sys.argv[2])
n = (len(data) + CH - 1) // CH
interval = dur / max(n, 1)
w = sys.stdout.buffer
t0 = time.monotonic()
for i in range(n):
    w.write(data[i*CH:(i+1)*CH])
    w.flush()
    target = t0 + (i + 1) * interval
    dt = target - time.monotonic()
    if dt > 0:
        time.sleep(dt)
PY

# Build the clean (padded) and dropped (one excised payload packet, padded) TS.
# Padding uses valid null TS packets (PID 0x1FFF) so the file length is a whole
# multiple of the 1316-byte SRT chunk and the parser still sees sync byte 0x47.
cat > "$BUILDER" <<'PY'
import sys
from collections import Counter
PKT = 188
CH = 1316
src, clean_out, dropped_out = sys.argv[1], sys.argv[2], sys.argv[3]

def null_pkt():
    # sync=0x47, PID=0x1FFF, afc=01 (payload), cc=0, then 0xFF stuffing
    return bytes([0x47, 0x1F, 0xFF, 0x10]) + b'\xff' * 184

def pad(d):
    while len(d) % CH != 0:
        d += null_pkt()
    return d

d = open(src, 'rb').read()
counts = Counter()
for i in range(0, len(d) - PKT + 1, PKT):
    if d[i] == 0x47:
        pid = ((d[i + 1] & 0x1F) << 8) | d[i + 2]
        if pid != 0x1FFF:
            counts[pid] += 1
if not counts:
    sys.exit('no non-null PIDs in source TS')
pid = counts.most_common(1)[0][0]
idxs = [i for i in range(0, len(d) - PKT + 1, PKT)
        if d[i] == 0x47 and (((d[i + 1] & 0x1F) << 8) | d[i + 2]) == pid]
drop = idxs[len(idxs) // 2]
open(clean_out, 'wb').write(pad(d))
open(dropped_out, 'wb').write(pad(d[:drop] + d[drop + PKT:]))
print('dominant_pid=0x%04x occurrences=%d dropped_off=%d' % (pid, len(idxs), drop))
PY

# --------------------------------------------------------------------------- #
# Build the fixtures.                                                          #
# --------------------------------------------------------------------------- #
log "==> ts-continuity-loopback (build dir: ${BUILD_DIR})"
ffmpeg -hide_banner -loglevel error -f lavfi -i "testsrc2=size=320x240:rate=25" \
  -t "$MEDIA_SEC" -c:v mpeg2video -b:v 1M -f mpegts "$CLEAN_TS" \
  || die "ffmpeg could not generate the source TS"
fixture_info="$(python3 "$BUILDER" "$CLEAN_TS" "$CLEAN_PAD_TS" "$DROPPED_TS")" \
  || die "fixture builder failed: ${fixture_info:-}"
log "    fixtures: ${fixture_info}"

# --------------------------------------------------------------------------- #
# Run one leg: SRT caller (paced raw send) -> srt-sink. Echoes nothing; the      #
# metrics are read from "$out".                                                  #
# --------------------------------------------------------------------------- #
run_leg() {
  local src="$1" out="$2" port="$3" txlog="$4" sinklog="$5"
  rm -f "$out"
  "$SRT_SINK" --port "$port" --host 127.0.0.1 --result "$out" \
              --latency "$SRT_LATENCY_MS" --duration "$SINK_DURATION" \
              >"$sinklog" 2>&1 &
  local sp=$!; PIDS+=("$sp")
  sleep 0.6
  ( python3 "$PACER" "$src" "$MEDIA_SEC" \
      | timeout "$TX_TIMEOUT" srt-live-transmit -t:"$SLT_EXIT_SEC" -chunk:1316 \
          "file://con" \
          "srt://127.0.0.1:${port}?mode=caller&transtype=live&latency=${SRT_LATENCY_MS}" \
  ) >"$txlog" 2>&1
  sleep 1.5
  kill -TERM "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
}

metric() { jq -r ".$2 // -1" "$1" 2>/dev/null || echo -1; }

log "==> CLEAN leg  (port ${SINK_PORT_CLEAN})"
run_leg "$CLEAN_PAD_TS" "$CLEAN_JSON" "$SINK_PORT_CLEAN" \
        "${RESULTS_DIR}/clean-tx.log" "${RESULTS_DIR}/clean-sink.log"
clean_pkts="$(metric "$CLEAN_JSON" ts_packets)"
clean_sync="$(metric "$CLEAN_JSON" ts_sync_errors)"
clean_cc="$(metric "$CLEAN_JSON" ts_cc_errors)"

log "==> DROPPED leg (port ${SINK_PORT_DROP})"
run_leg "$DROPPED_TS" "$DROP_JSON" "$SINK_PORT_DROP" \
        "${RESULTS_DIR}/dropped-tx.log" "${RESULTS_DIR}/dropped-sink.log"
drop_pkts="$(metric "$DROP_JSON" ts_packets)"
drop_sync="$(metric "$DROP_JSON" ts_sync_errors)"
drop_cc="$(metric "$DROP_JSON" ts_cc_errors)"

for v in "$clean_pkts" "$clean_sync" "$clean_cc" "$drop_pkts" "$drop_sync" "$drop_cc"; do
  [[ "$v" =~ ^-?[0-9]+$ ]] || die "could not read TS metrics from a result file"
done

# --------------------------------------------------------------------------- #
# Verdict.                                                                     #
# --------------------------------------------------------------------------- #
clean_ok=false
[[ "$clean_pkts" -gt 0 && "$clean_sync" -eq 0 && "$clean_cc" -eq 0 ]] && clean_ok=true
dropped_ok=false
[[ "$drop_cc" -gt 0 ]] && dropped_ok=true

pass=false
[[ "$clean_ok" == true && "$dropped_ok" == true ]] && pass=true

jq -n \
  --argjson pass "$pass" \
  --argjson clean_ok "$clean_ok" --argjson dropped_ok "$dropped_ok" \
  --argjson clean_pkts "$clean_pkts" --argjson clean_sync "$clean_sync" --argjson clean_cc "$clean_cc" \
  --argjson drop_pkts "$drop_pkts" --argjson drop_sync "$drop_sync" --argjson drop_cc "$drop_cc" \
  --argjson media_sec "$MEDIA_SEC" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    scenario:"ts-continuity-loopback", pass:$pass,
    criteria:{clean_ok:$clean_ok, dropped_ok:$dropped_ok},
    clean:{ts_packets:$clean_pkts, ts_sync_errors:$clean_sync, ts_cc_errors:$clean_cc},
    dropped:{ts_packets:$drop_pkts, ts_sync_errors:$drop_sync, ts_cc_errors:$drop_cc},
    media_sec:$media_sec, timestamp:$ts
  }' > "$RESULT_JSON"

log ""
log "ts-continuity-loopback: clean_cc=${clean_cc} clean_sync=${clean_sync} dropped_cc=${drop_cc} clean_pkts=${clean_pkts} dropped_pkts=${drop_pkts}"
log ""
log "================ ts-continuity-loopback summary ================"
log "  clean_ok=${clean_ok}   (pkts=${clean_pkts} sync=${clean_sync} cc=${clean_cc} — expect cc=0,sync=0)"
log "  dropped_ok=${dropped_ok} (pkts=${drop_pkts} sync=${drop_sync} cc=${drop_cc} — expect cc>0)"
log "  result: ${RESULT_JSON}"
log "==============================================================="

if [[ "$KEEP_LOGS" -eq 0 && "$pass" == true ]]; then
  rm -f "${RESULTS_DIR}/clean-tx.log" "${RESULTS_DIR}/clean-sink.log" \
        "${RESULTS_DIR}/dropped-tx.log" "${RESULTS_DIR}/dropped-sink.log" \
        "$CLEAN_TS" "$CLEAN_PAD_TS" "$DROPPED_TS" "$PACER" "$BUILDER"
fi

if [[ "$pass" == true ]]; then log "PASS"; exit 0; else log "FAIL"; exit 1; fi

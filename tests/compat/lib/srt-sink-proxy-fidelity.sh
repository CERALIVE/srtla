#!/usr/bin/env bash
#
# srt-sink-proxy-fidelity.sh — prove srt-sink reproduces irl-srt-server's
# kSrtProfileTable L1/L2 receive profiles, measured by the SAME sockopt set
# the campaign drives (--nakreport / --reorderfreeze / --lossmaxttl).
#
# WHY THIS EXISTS (Codex blocker B2): the FEC/NAK campaign measures via
# srt-sink, but production NAK / freeze / TTL live in irl-srt-server's
# kSrtProfileTable (src/core/SLSSrt.cpp). For a campaign number to be a valid
# proxy for a production profile, srt-sink must apply the SAME negotiated policy
# on the accepted socket. srt-sink now reads it back from the accepted socket
# (srt_getsockflag for SRTO_NAKREPORT, SRTO_LOSSMAXTTL, and opt id 120 for
# SRTO_REORDERFREEZE) into result.json — NOT the requested values its banner
# echoes. This script asserts those read-backs equal the irl-srt-server tuples.
#
# irl-srt-server kSrtProfileTable (SLSSrt.cpp:201-205), the tuples reproduced:
#   L1-freeze-nak : {freeze=1, nakreport=1, lossmaxttl=40}  (+ fec-accept)
#   L2-classic    : {freeze=1, nakreport=0, lossmaxttl=40}
#   (L3-direct uses the libsrt default NAK + lossmaxttl=200; not a srtla path.)
#
# Falsifiability (the whole point of a read-back vs an echo): the QA leg runs
# the L2 flags but with --lossmaxttl 30 and asserts the fidelity check FAILS,
# naming the mismatch. If srt-sink merely echoed the requested value the check
# would still "pass" against the 30 it was told; it FAILS because it compares the
# value libsrt actually negotiated on the socket against the L2 tuple's 40.
#
# Privilege: NONE. Requires srt-live-transmit (libsrt-tools) and jq; without
# srt-live-transmit the script SKIPs cleanly (exit 3) like the other
# capability-gated scenarios.
#
# Usage:
#   srt-sink-proxy-fidelity.sh [--build-dir DIR] [--duration SEC] [--keep-logs] [-h]
#     --duration SEC   per-leg stream length (default 3).
#
# Output (repo-local, gitignored — Rule D, never escapes the srtla checkout):
#   test-results/srt-sink-proxy-fidelity.json
#     profile map: campaign label -> srt-sink flags -> irl-srt-server profile,
#     each with the read-back tuple and a per-leg pass flag.
#
# Exit: 0 if the L1+L2 fidelity legs match AND the QA mismatch leg fails as
# required; 1 on any fidelity violation; 2 on a harness error; 3 on SKIP.
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." >/dev/null 2>&1 && pwd -P)"
OUT_DIR="${REPO_ROOT}/test-results"
RESULT_JSON="${OUT_DIR}/srt-sink-proxy-fidelity.json"

log() { printf '%s\n' "$*" >&2; }
die() { printf 'srt-sink-proxy-fidelity: %s\n' "$*" >&2; exit 2; }

# --------------------------------------------------------------------------- #
# CLI                                                                         #
# --------------------------------------------------------------------------- #
BUILD_DIR="${SRTLA_BUILD_DIR:-}"
KEEP_LOGS=0
MEDIA_SEC=3

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir) BUILD_DIR="${2:?--build-dir needs a value}"; shift 2 ;;
    --duration)  MEDIA_SEC="${2:?--duration needs a value}"; shift 2 ;;
    --keep-logs) KEEP_LOGS=1; shift ;;
    -h|--help)   sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown argument '$1' (try --help)" ;;
  esac
done
[[ "$MEDIA_SEC" =~ ^[0-9]+$ && "$MEDIA_SEC" -ge 1 ]] || die "--duration must be a positive integer"

command -v jq >/dev/null 2>&1 || die "required tool 'jq' not found in PATH"
if ! command -v srt-live-transmit >/dev/null 2>&1; then
  log "SKIP srt-sink-proxy-fidelity: srt-live-transmit not found (install libsrt-tools)"
  mkdir -p "$OUT_DIR"
  printf '{"check":"srt-sink-proxy-fidelity","skipped":true,"reason":"srt-live-transmit not installed"}\n' \
    > "$RESULT_JSON"
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
# Constants.                                                                  #
# --------------------------------------------------------------------------- #
SRT_LATENCY_MS=300
SINK_DURATION=$((MEDIA_SEC + 12))
TX_TIMEOUT=$((MEDIA_SEC + 9))
SLT_EXIT_SEC=$((MEDIA_SEC + 3))
PAYLOAD_BYTES=$((MEDIA_SEC * 130000))

WORK="$(mktemp -d)"
PAYGEN="${WORK}/paygen.py"
PIDS=()
cleanup() {
  local p; for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill -TERM "$p" 2>/dev/null; done
  [[ "$KEEP_LOGS" -eq 0 ]] && rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# Fixed-pattern 1316-byte (7x188) chunks paced over MEDIA_SEC so the live socket
# sees a real-time stream, not a loss-inducing burst (content is irrelevant —
# this check reads sockopts, not payload).
cat > "$PAYGEN" <<'PY'
import sys, time
total = int(sys.argv[1]); dur = float(sys.argv[2])
CH = 1316
chunk = bytes(i % 256 for i in range(CH))
n = max(total // CH, 1)
interval = dur / n
w = sys.stdout.buffer
t0 = time.monotonic()
for i in range(n):
    w.write(chunk); w.flush()
    target = t0 + (i + 1) * interval
    dt = target - time.monotonic()
    if dt > 0:
        time.sleep(dt)
PY

# --------------------------------------------------------------------------- #
# Run one leg: srt-sink with the given flags <- a plain SRT caller. Reads the   #
# three negotiated sockopts back from result.json. Sets globals RB_NAK / RB_TTL #
# / RB_FREEZE / RB_BYTES.                                                        #
# --------------------------------------------------------------------------- #
run_leg() {
  local name="$1" freeze="$2" nak="$3" ttl="$4" port="$5"
  local res="${WORK}/${name}.json"
  local sinklog="${WORK}/${name}-sink.log"
  local calllog="${WORK}/${name}-call.log"
  rm -f "$res"

  "$SRT_SINK" --port "$port" --host 127.0.0.1 --result "$res" \
    --latency "$SRT_LATENCY_MS" --duration "$SINK_DURATION" \
    --reorderfreeze "$freeze" --nakreport "$nak" --lossmaxttl "$ttl" \
    >"$sinklog" 2>&1 &
  local sp=$!; PIDS+=("$sp")
  sleep 0.7

  local curl="srt://127.0.0.1:${port}?mode=caller&transtype=live&latency=${SRT_LATENCY_MS}"
  ( python3 "$PAYGEN" "$PAYLOAD_BYTES" "$MEDIA_SEC" \
      | timeout "$TX_TIMEOUT" srt-live-transmit -t:"$SLT_EXIT_SEC" -chunk:1316 \
          "file://con" "$curl" ) >"$calllog" 2>&1 || true
  sleep 1.0
  kill -TERM "$sp" 2>/dev/null; wait "$sp" 2>/dev/null

  RB_BYTES="$(jq -r '.bytes_received // -1'        "$res" 2>/dev/null || echo -1)"
  RB_NAK="$(jq -r '.nakreport_readback // -99'     "$res" 2>/dev/null || echo -99)"
  RB_TTL="$(jq -r '.lossmaxttl_readback // -99'    "$res" 2>/dev/null || echo -99)"
  RB_FREEZE="$(jq -r '.reorderfreeze_readback // -99' "$res" 2>/dev/null || echo -99)"
  [[ "$RB_BYTES" =~ ^-?[0-9]+$ ]] || RB_BYTES=-1
}

# Assert a leg's read-back equals an expected {freeze,nak,ttl} tuple. Echoes a
# human reason; returns 0 on match, 1 on mismatch. A leg that never accepted a
# caller (RB_*= -99 / -1) is a mismatch, not a pass.
assert_tuple() {
  local exp_freeze="$1" exp_nak="$2" exp_ttl="$3"
  local ok=1 reasons=()
  [[ "$RB_BYTES" -ge 1000 ]] || { ok=0; reasons+=("no stream (bytes=${RB_BYTES})"); }
  [[ "$RB_FREEZE" == "$exp_freeze" ]] || { ok=0; reasons+=("freeze ${RB_FREEZE}!=${exp_freeze}"); }
  [[ "$RB_NAK"    == "$exp_nak"    ]] || { ok=0; reasons+=("nak ${RB_NAK}!=${exp_nak}"); }
  [[ "$RB_TTL"    == "$exp_ttl"    ]] || { ok=0; reasons+=("ttl ${RB_TTL}!=${exp_ttl}"); }
  if [[ "$ok" -eq 1 ]]; then ASSERT_REASON="match {freeze=${RB_FREEZE},nak=${RB_NAK},ttl=${RB_TTL}}"; return 0; fi
  ASSERT_REASON="$(IFS='; '; echo "${reasons[*]}")"; return 1
}

# --------------------------------------------------------------------------- #
# Leg 1 — L2 Classic fidelity. srt-sink {freeze=1,nak=0,ttl=40} must read back   #
# the irl-srt-server L2-classic tuple.                                          #
# --------------------------------------------------------------------------- #
log "==> srt-sink-proxy-fidelity (build dir: ${BUILD_DIR})"

run_leg "l2-classic" 1 0 40 4901
L2_NAK="$RB_NAK"; L2_TTL="$RB_TTL"; L2_FREEZE="$RB_FREEZE"; L2_BYTES="$RB_BYTES"
if assert_tuple 1 0 40; then l2_pass=true; else l2_pass=false; fi
L2_REASON="$ASSERT_REASON"
log "    L2-classic   : freeze=${L2_FREEZE} nak=${L2_NAK} ttl=${L2_TTL} -> pass=${l2_pass} (${L2_REASON})"

# --------------------------------------------------------------------------- #
# Leg 2 — L1 freeze+NAK fidelity. srt-sink {freeze=1,nak=1,ttl=40} must read     #
# back the irl-srt-server L1-freeze-nak tuple.                                  #
# --------------------------------------------------------------------------- #
run_leg "l1-freeze-nak" 1 1 40 4902
L1_NAK="$RB_NAK"; L1_TTL="$RB_TTL"; L1_FREEZE="$RB_FREEZE"; L1_BYTES="$RB_BYTES"
if assert_tuple 1 1 40; then l1_pass=true; else l1_pass=false; fi
L1_REASON="$ASSERT_REASON"
log "    L1-freeze-nak: freeze=${L1_FREEZE} nak=${L1_NAK} ttl=${L1_TTL} -> pass=${l1_pass} (${L1_REASON})"

# --------------------------------------------------------------------------- #
# Leg 3 — QA falsifier. Run the L2 flags but with --lossmaxttl 30 and assert the #
# L2 fidelity check FAILS, naming the ttl mismatch. This proves the result.json  #
# value is the negotiated read-back, not the echoed request (an echo of 30 vs    #
# the L2 tuple's 40 still mismatches — but the value MUST be the real 30 libsrt   #
# set on the socket, which it is).                                              #
# --------------------------------------------------------------------------- #
run_leg "qa-ttl30" 1 0 30 4903
QA_NAK="$RB_NAK"; QA_TTL="$RB_TTL"; QA_FREEZE="$RB_FREEZE"; QA_BYTES="$RB_BYTES"
# Expect a MISMATCH against the L2 tuple (ttl 40); assert_tuple returns non-zero.
if assert_tuple 1 0 40; then qa_falsifies=false; else qa_falsifies=true; fi
QA_REASON="$ASSERT_REASON"
# The read-back must be the real 30 (proves it is not the L2-tuple 40 echoed back).
qa_reads_real=false
[[ "$QA_TTL" == "30" ]] && qa_reads_real=true
log "    QA ttl=30    : freeze=${QA_FREEZE} nak=${QA_NAK} ttl=${QA_TTL} -> fidelity_fails=${qa_falsifies} reads_real_30=${qa_reads_real} (${QA_REASON})"

# --------------------------------------------------------------------------- #
# Verdict + profile map.                                                       #
# --------------------------------------------------------------------------- #
overall=false
[[ "$l2_pass" == true && "$l1_pass" == true \
   && "$qa_falsifies" == true && "$qa_reads_real" == true ]] && overall=true

mkdir -p "$OUT_DIR"
jq -n \
  --argjson overall "$overall" \
  --argjson l1_pass "$l1_pass" --argjson l2_pass "$l2_pass" \
  --argjson qa_falsifies "$qa_falsifies" --argjson qa_reads_real "$qa_reads_real" \
  --argjson l1_freeze "$L1_FREEZE" --argjson l1_nak "$L1_NAK" --argjson l1_ttl "$L1_TTL" --argjson l1_bytes "$L1_BYTES" \
  --argjson l2_freeze "$L2_FREEZE" --argjson l2_nak "$L2_NAK" --argjson l2_ttl "$L2_TTL" --argjson l2_bytes "$L2_BYTES" \
  --argjson qa_freeze "$QA_FREEZE" --argjson qa_nak "$QA_NAK" --argjson qa_ttl "$QA_TTL" --argjson qa_bytes "$QA_BYTES" \
  --arg l1_reason "$L1_REASON" --arg l2_reason "$L2_REASON" --arg qa_reason "$QA_REASON" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    check: "srt-sink-proxy-fidelity",
    overall_pass: $overall,
    measured_via: "srt_getsockflag on the accepted socket (SRTO_NAKREPORT, SRTO_LOSSMAXTTL, opt id 120 for SRTO_REORDERFREEZE)",
    source_of_truth: "irl-srt-server src/core/SLSSrt.cpp kSrtProfileTable (L1/L2/L3)",
    profile_map: {
      "Balanced/Low-Latency/Resilient (+Low-Latency+FEC)": {
        srtla_campaign_label: "L1",
        srt_sink_flags: "--reorderfreeze 1 --nakreport 1 --lossmaxttl 40",
        reproduces_irl_srt_server_profile: "L1-freeze-nak",
        expected_tuple: {freeze: 1, nakreport: 1, lossmaxttl: 40},
        readback_tuple: {freeze: $l1_freeze, nakreport: $l1_nak, lossmaxttl: $l1_ttl},
        bytes_received: $l1_bytes,
        pass: $l1_pass,
        note: $l1_reason
      },
      "Classic (Baseline B)": {
        srtla_campaign_label: "L2",
        srt_sink_flags: "--reorderfreeze 1 --nakreport 0 --lossmaxttl 40",
        reproduces_irl_srt_server_profile: "L2-classic",
        expected_tuple: {freeze: 1, nakreport: 0, lossmaxttl: 40},
        readback_tuple: {freeze: $l2_freeze, nakreport: $l2_nak, lossmaxttl: $l2_ttl},
        bytes_received: $l2_bytes,
        pass: $l2_pass,
        note: $l2_reason
      }
    },
    qa_falsifier: {
      description: "L2 flags with --lossmaxttl 30 must FAIL the L2 (ttl=40) fidelity check, proving the read-back is the negotiated value not the echoed request",
      srt_sink_flags: "--reorderfreeze 1 --nakreport 0 --lossmaxttl 30",
      readback_tuple: {freeze: $qa_freeze, nakreport: $qa_nak, lossmaxttl: $qa_ttl},
      bytes_received: $qa_bytes,
      fidelity_check_failed_as_required: $qa_falsifies,
      readback_is_real_30_not_echoed_40: $qa_reads_real,
      mismatch: $qa_reason
    },
    timestamp: $ts
  }' > "$RESULT_JSON"

log ""
log "================ srt-sink-proxy-fidelity summary ================"
log "  L1-freeze-nak reproduced : ${l1_pass}"
log "  L2-classic reproduced    : ${l2_pass}"
log "  QA ttl=30 falsifier fails: ${qa_falsifies} (reads real 30: ${qa_reads_real})"
log "  result: ${RESULT_JSON}"
log "================================================================"

if [[ "$overall" == true ]]; then log "PASS"; exit 0; else log "FAIL"; exit 1; fi

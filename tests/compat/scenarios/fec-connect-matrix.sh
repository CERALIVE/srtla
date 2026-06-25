#!/usr/bin/env bash
#
# fec-connect-matrix.sh — proves SRT's one-sided packet-filter (FEC) connect
# negotiation against a single "fec-accept" listener (SRTO_PACKETFILTER=fec),
# the receiver profile (L1) that the device's FEC senders ride.
#
# Each case runs a real SRT caller (srt-live-transmit, FEC-capable) into an
# srt-sink listener over 127.0.0.1 and reads the connection's negotiated filter
# from the sink's --result JSON ("packetfilter": the SRTO_PACKETFILTER value on
# the accepted data socket — non-empty when FEC was agreed, "" when cleared):
#
#   (a) FEC caller   -> fec-accept listener  : FEC NEGOTIATED.
#       caller sets the full config (fec,layout:staircase,rows:10,cols:10,
#       arq:onreq); the listener sets just the type (fec). The accepted socket
#       reports a non-empty merged config and bytes flow.
#
#   (b) plain caller -> fec-accept listener  : connects PLAIN, NOT rejected.
#       the SAME listener with no FEC caller clears its filter for that one
#       connection (responder branch, core.cpp checkApplyFilterConfig). The
#       accepted socket reports an EMPTY packetfilter and bytes flow. This is
#       why ONE fec-accept listener serves BOTH FEC and non-FEC (BELABOX) senders
#       and no separate FEC port is needed.
#
#   (c) FEC caller   -> conflicting-filter listener : HARD REJECT (SRT_REJ_FILTER).
#       when the listener's filter config is irreconcilable with the caller's,
#       the handshake is rejected: the caller logs ERROR:FILTER and the sink
#       never accepts (bytes_received == 0). This is the genuine reject boundary.
#
#   (d) FEC caller   -> no-filter listener   : ADOPTS (informational, NOT gated).
#       a listener with NO packetfilter does NOT reject a FEC caller — it takes
#       the caller's config as a "good deal" and runs FEC anyway. So the reject
#       boundary in (c) is a config CONFLICT, never the mere ABSENCE of a filter.
#       Reported for completeness; the pass gate is (a) && (b) && (c).
#
# Falsifiability: (a) and (b) share the identical listener (--packetfilter fec)
# yet must report opposite results (non-empty vs empty), so neither can be
# hard-coded; (c) must produce a real SRT_REJ_FILTER with zero bytes.
#
# Privilege: NONE. Requires srt-live-transmit (libsrt-tools); without it the
# scenario SKIPs cleanly (exit 3), like the other capability-gated scenarios.
#
# Usage:
#   fec-connect-matrix.sh [--build-dir DIR] [--duration SEC] [--keep-logs] [-h]
#     --duration SEC   per-case stream length (default 3).
#
# Artifacts land in tests/compat/results/fec-connect-matrix/ (gitignored);
# nothing is written outside the repo and no `../`-escaping path is used (Rule D).
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." >/dev/null 2>&1 && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../results/fec-connect-matrix"

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'fec-connect-matrix: %s\n' "$*" >&2; exit 2; }

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

for tool in jq python3; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' not found in PATH"
done
if ! command -v srt-live-transmit >/dev/null 2>&1; then
  log "SKIP fec-connect-matrix: srt-live-transmit not found (install libsrt-tools)"
  mkdir -p "$RESULTS_DIR"
  printf '{"scenario":"fec-connect-matrix","skipped":true,"reason":"srt-live-transmit not installed"}\n' \
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
# Constants / filter configs                                                  #
# --------------------------------------------------------------------------- #
FEC_FULL="fec,layout:staircase,rows:10,cols:10,arq:onreq"   # device FEC sender
FEC_ACCEPT="fec"                                            # L1 fec-accept form
FEC_CONFLICT="fec,layout:even,rows:20,cols:20,arq:always"   # irreconcilable dims

SRT_LATENCY_MS=300
SINK_DURATION=$((MEDIA_SEC + 12))     # sink self-timeout guard, past the send
TX_TIMEOUT=$((MEDIA_SEC + 9))         # hard cap on a hung srt-live-transmit
SLT_EXIT_SEC=$((MEDIA_SEC + 3))       # srt-live-transmit's own since-start timer
PAYLOAD_BYTES=$((MEDIA_SEC * 130000)) # ~1 Mbit/s of bytes, paced to real time

rm -rf "$RESULTS_DIR"; mkdir -p "$RESULTS_DIR"
PAYGEN="${RESULTS_DIR}/paygen.py"
RESULT_JSON="${RESULTS_DIR}/result.json"

PIDS=()
cleanup() { local p; for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill -TERM "$p" 2>/dev/null; done; }
trap cleanup EXIT INT TERM

# Emit PAYLOAD_BYTES of content as whole 1316-byte (7x188) chunks, paced over
# MEDIA_SEC so the SRT live socket sees a real-time stream, not a loss-inducing
# burst. Content is irrelevant here (we count bytes, not TS), so it is a fixed
# pattern; full chunks avoid a short final message.
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
# Run one case: srt-sink listener (optional --packetfilter) <- FEC/plain caller. #
# Sets globals: R_BYTES, R_FILTER, R_REJECT (1 if caller saw a filter reject).    #
# --------------------------------------------------------------------------- #
run_case() {
  local name="$1" sink_pf="$2" call_pf="$3" port="$4"
  local res="${RESULTS_DIR}/${name}.json"
  local sinklog="${RESULTS_DIR}/${name}-sink.log"
  local calllog="${RESULTS_DIR}/${name}-call.log"
  rm -f "$res"

  local sinkargs=(--port "$port" --host 127.0.0.1 --result "$res"
                  --latency "$SRT_LATENCY_MS" --duration "$SINK_DURATION")
  [[ -n "$sink_pf" ]] && sinkargs+=(--packetfilter "$sink_pf")
  "$SRT_SINK" "${sinkargs[@]}" >"$sinklog" 2>&1 &
  local sp=$!; PIDS+=("$sp")
  sleep 0.7

  local curl="srt://127.0.0.1:${port}?mode=caller&transtype=live&latency=${SRT_LATENCY_MS}"
  [[ -n "$call_pf" ]] && curl="${curl}&packetfilter=${call_pf}"
  ( python3 "$PAYGEN" "$PAYLOAD_BYTES" "$MEDIA_SEC" \
      | timeout "$TX_TIMEOUT" srt-live-transmit -t:"$SLT_EXIT_SEC" -chunk:1316 \
          "file://con" "$curl" ) >"$calllog" 2>&1 || true
  sleep 1.0
  kill -TERM "$sp" 2>/dev/null; wait "$sp" 2>/dev/null

  R_BYTES="$(jq -r '.bytes_received // -1' "$res" 2>/dev/null || echo -1)"
  R_FILTER="$(jq -r '.packetfilter // ""' "$res" 2>/dev/null || echo "")"
  if grep -qiE "ERROR:FILTER|Packet Filter settings error|REJECT reported from HS" "$calllog"; then
    R_REJECT=1
  else
    R_REJECT=0
  fi
  [[ "$R_BYTES" =~ ^-?[0-9]+$ ]] || R_BYTES=-1
}

# --------------------------------------------------------------------------- #
# Execute the matrix.                                                         #
# --------------------------------------------------------------------------- #
log "==> fec-connect-matrix (build dir: ${BUILD_DIR})"

run_case "case-a-fec-to-fecaccept" "$FEC_ACCEPT" "$FEC_FULL" 4871
A_BYTES="$R_BYTES"; A_FILTER="$R_FILTER"; A_REJECT="$R_REJECT"
log "    (a) FEC -> fec-accept : bytes=${A_BYTES} filter='${A_FILTER}' reject=${A_REJECT}"

run_case "case-b-plain-to-fecaccept" "$FEC_ACCEPT" "" 4872
B_BYTES="$R_BYTES"; B_FILTER="$R_FILTER"; B_REJECT="$R_REJECT"
log "    (b) plain -> fec-accept : bytes=${B_BYTES} filter='${B_FILTER}' reject=${B_REJECT}"

run_case "case-c-fec-to-conflict" "$FEC_CONFLICT" "$FEC_FULL" 4873
C_BYTES="$R_BYTES"; C_FILTER="$R_FILTER"; C_REJECT="$R_REJECT"
log "    (c) FEC -> conflict : bytes=${C_BYTES} filter='${C_FILTER}' reject=${C_REJECT}"

run_case "case-d-fec-to-empty" "" "$FEC_FULL" 4874
D_BYTES="$R_BYTES"; D_FILTER="$R_FILTER"; D_REJECT="$R_REJECT"
log "    (d) FEC -> no-filter : bytes=${D_BYTES} filter='${D_FILTER}' reject=${D_REJECT} (informational)"

# --------------------------------------------------------------------------- #
# Verdict.                                                                     #
# --------------------------------------------------------------------------- #
a_ok=false
[[ "$A_BYTES" -ge 1000 && "$A_REJECT" -eq 0 && -n "$A_FILTER" && "$A_FILTER" == fec* ]] && a_ok=true
b_ok=false
[[ "$B_BYTES" -ge 1000 && "$B_REJECT" -eq 0 && -z "$B_FILTER" ]] && b_ok=true
c_ok=false
[[ "$C_BYTES" -eq 0 && "$C_REJECT" -eq 1 && -z "$C_FILTER" ]] && c_ok=true
# (d) is informational: a no-filter listener adopts the caller's FEC config.
d_adopts=false
[[ "$D_BYTES" -ge 1000 && "$D_REJECT" -eq 0 && -n "$D_FILTER" && "$D_FILTER" == fec* ]] && d_adopts=true

pass=false
[[ "$a_ok" == true && "$b_ok" == true && "$c_ok" == true ]] && pass=true

jq -n \
  --argjson pass "$pass" \
  --argjson a_ok "$a_ok" --argjson b_ok "$b_ok" --argjson c_ok "$c_ok" \
  --argjson d_adopts "$d_adopts" \
  --argjson a_bytes "$A_BYTES" --arg a_filter "$A_FILTER" --argjson a_reject "$A_REJECT" \
  --argjson b_bytes "$B_BYTES" --arg b_filter "$B_FILTER" --argjson b_reject "$B_REJECT" \
  --argjson c_bytes "$C_BYTES" --arg c_filter "$C_FILTER" --argjson c_reject "$C_REJECT" \
  --argjson d_bytes "$D_BYTES" --arg d_filter "$D_FILTER" --argjson d_reject "$D_REJECT" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    scenario:"fec-connect-matrix", pass:$pass,
    criteria:{a_fec_negotiated:$a_ok, b_plain_accepted:$b_ok, c_hard_reject:$c_ok},
    cases:{
      a_fec_to_fecaccept:{bytes:$a_bytes, packetfilter:$a_filter, reject:$a_reject},
      b_plain_to_fecaccept:{bytes:$b_bytes, packetfilter:$b_filter, reject:$b_reject},
      c_fec_to_conflict:{bytes:$c_bytes, packetfilter:$c_filter, reject:$c_reject},
      d_fec_to_empty_informational:{bytes:$d_bytes, packetfilter:$d_filter, reject:$d_reject, adopts:$d_adopts}
    },
    timestamp:$ts
  }' > "$RESULT_JSON"

log ""
log "================ fec-connect-matrix summary ================"
log "  (a) FEC negotiated   : ${a_ok}  (bytes=${A_BYTES} filter='${A_FILTER}' — expect non-empty fec)"
log "  (b) plain accepted   : ${b_ok}  (bytes=${B_BYTES} filter='${B_FILTER}' — expect empty, NOT rejected)"
log "  (c) hard reject      : ${c_ok}  (bytes=${C_BYTES} reject=${C_REJECT} — expect SRT_REJ_FILTER, 0 bytes)"
log "  (d) no-filter adopts : ${d_adopts}  (bytes=${D_BYTES} filter='${D_FILTER}' — informational, not gated)"
log "  result: ${RESULT_JSON}"
log "==========================================================="

if [[ "$KEEP_LOGS" -eq 0 && "$pass" == true ]]; then
  rm -f "${RESULTS_DIR}"/case-*-sink.log "${RESULTS_DIR}"/case-*-call.log \
        "${RESULTS_DIR}"/case-*.json "$PAYGEN"
fi

if [[ "$pass" == true ]]; then log "PASS"; exit 0; else log "FAIL"; exit 1; fi

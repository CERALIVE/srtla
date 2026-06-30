#!/usr/bin/env bash
#
# gain-hunt-matrix.sh — ORCHESTRATOR for the FEC×NAK×FREEZE receiver gain hunt.
#
# WHAT THIS IS: the falsifiable driver of the campaign that decides whether any
# receiver recipe — a FEC packet-filter mixture and/or the periodic-NAK / decay-
# freeze knobs — beats the BELABOX-parity baseline enough to earn a place in the
# operator-facing receiver-capability catalog. The catalog ships EMPTY; a recipe
# is added ONLY after this campaign produces evidence that clears the pre-
# registered gate below. The decision rule and the candidate matrix are fixed in
# code BEFORE any data is collected (mirroring ADR-002), so a positive result
# cannot be a post-hoc story. The full protocol lives in
# docs/GAIN-HUNT-PROTOCOL.md; this header is the executable echo of it.
#
# This driver wires the instrument (scenarios/reorder-stress.sh) for the SCREEN
# matrix and a 1-cell --smoke self-test. The deep stage (per-cell adverse-axis
# sweep + FEC-geometry sweep + Holm-Bonferroni stats) is the --stage deep seam,
# filled in by a follow-up effort (T-A6). The campaign's PRIMARY sender is the
# Rust fork srtla-send-rs (ADR-003): a run with no srtla-send-rs resolvable SKIPs
# (exit 77) rather than measure the deprecated C srtla_send as if it were production.
#
# ===================== PRE-REGISTERED DECISION RULE =========================
# "real gain + no regression" — fixed HERE, before any measurement exists. A
# candidate recipe C beats the BELABOX-parity baseline B (Classic L2 + latency,
# REORDERFREEZE=1 NAKREPORT=0 LOSSMAXTTL=40, ARQ always on; see
# docs/RECEIVER-RECONCILIATION.md) on a per-cell basis ONLY if BOTH halves hold
# across the adverse-config matrix, paired/alternating, shared per-rep netem seed,
# with a Holm-Bonferroni correction across cells:
#
#   REAL GAIN (C must WIN at least one primary metric, beyond noise):
#     * median goodput_bps(C) >= 1.03 x median goodput_bps(B)            (>=3% up), OR
#     * median pkt_rcv_drop(C) <= 0.80 x median pkt_rcv_drop(B)         (>=20% fewer
#       late-drops) with goodput non-inferior (>= 99% of B).
#     The win must be significant at alpha=0.05 (Mann-Whitney U, Holm-corrected),
#     not a single lucky rep.
#
#   NO REGRESSION (C must not LOSE any guardrail vs B):
#     * disconnects == 0 in every C rep (hard gate; one disconnect = candidate out).
#     * ts_sync_errors(C) == 0 and ts_cc_errors(C) <= ts_cc_errors(B) (median).
#     * goodput_bps(C) >= 0.99 x goodput_bps(B) (no goodput regression to buy drops).
#     * wire_amp(C) <= 1.10 x wire_amp(B) (forward FEC overhead is bounded).
#     * reverse_wire_amp(C) <= 1.10 x reverse_wire_amp(B) (periodic-NAK's reverse-
#       channel cost is bounded — NAK-on cannot buy a forward gain by flooding the
#       receiver->sender path; this is why the instrument now meters reverse bytes).
#     * p95 pkt_rcv_drop(C) <= p95 pkt_rcv_drop(B) (no tail-latency regression).
#
#   VERDICT: a recipe earns its catalog button ONLY if it shows REAL GAIN in at
#   least one adverse cell AND NO REGRESSION in EVERY cell. A gain in one cell
#   bought by a regression in another is NOT a win. Ties and "equal" outcomes keep
#   the baseline (catalog stays empty) — the burden of proof is on the candidate.
# ============================================================================
#
# ===================== CANDIDATE MATRIX (FEC × NAK × FREEZE) ================
# Three binary axes define the screen matrix (2 x 2 x 2 = 8 tuples). The baseline
# tuple is one of the eight; the other 7 are candidates measured against it:
#
#   REORDERFREEZE  in {1, 0}    decay-freeze on/off (SRTO_REORDERFREEZE)
#   NAKREPORT      in {0, 1}    periodic NAK report off/on (SRTO_NAKREPORT)
#   FEC            in {off, on} on = caller packetfilter "fec,cols:16,rows:1,
#                               layout:even,arq:onreq" (~6% column-only parity)
#   LOSSMAXTTL     = 40         held constant (BELABOX-parity reorder-tolerance cap)
#
#   BASELINE  B = REORDERFREEZE=1 NAKREPORT=0 FEC=off  (Classic L2 + latency)
#
# FEC is ALWAYS the arq:onreq hybrid (FEC parity + ARQ retransmit on demand). Pure
# FEC (arq:never) is BANNED across the whole stack — it has no retransmit floor and
# regressed on every prior trial. The orchestrator REFUSES (exit 2) any tuple whose
# packetfilter contains arq:never, in every mode, so a banned recipe can never even
# be enumerated, let alone promoted. The FEC geometry sweep (m-even-8x8 … staircase)
# and the loss/RTT adverse axes (STEADY_LOSS_PCT / BURST_LOSS_PCT / RTT_SPREAD_MS)
# are the DEEP stage's job (--stage deep, T-A6); the screen matrix fixes one cheap
# geometry and isolates the FEC/NAK/FREEZE recipe axes first.
# ============================================================================
#
# Usage:
#   gain-hunt-matrix.sh                 print this notice + matrix summary (exit 0)
#   gain-hunt-matrix.sh --dry-run       print the full 3-axis matrix + SRTO tuples (exit 0)
#   gain-hunt-matrix.sh --smoke         run ONE paired cell (candidate vs baseline),
#                                       bounded time, per-rep JSON (needs CAP_NET_ADMIN
#                                       + srtla-send-rs; else SKIP exit 77)
#   gain-hunt-matrix.sh --stage screen  run the full screen matrix (T-A6 seam; minimal)
#   gain-hunt-matrix.sh --stage deep    run the deep adverse sweep   (T-A6 seam; minimal)
#   gain-hunt-matrix.sh --help          this header (exit 0)
#   gain-hunt-matrix.sh --claim-gain …  attempt to assert a gain. REFUSED (exit 3) —
#                                       a gain cannot be claimed by running this
#                                       script; only the measured campaign + the §2
#                                       rule may. This is the falsifiability anchor.
#
# Sender: SRTLA_SEND_RS_BIN (or a srtla_send_rs on PATH) selects the Rust fork as
# the production sender; run modes SKIP (exit 77) when it is absent.
# Rule D: writes nothing above the srtla repo root (results stay in tests/compat/).
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." >/dev/null 2>&1 && pwd)"
PROTOCOL_DOC="${SCRIPT_DIR}/../../../docs/GAIN-HUNT-PROTOCOL.md"
REORDER="${SCRIPT_DIR}/reorder-stress.sh"
REORDER_RESULT="${SCRIPT_DIR}/../results/reorder-stress/result.json"
NETEM_LIB="${SCRIPT_DIR}/../lib/netem.sh"
RESULTS_DIR="${SCRIPT_DIR}/../results/gain-hunt-matrix"

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'gain-hunt-matrix: %s\n' "$*" >&2; exit 2; }

# --------------------------------------------------------------------------- #
# Matrix constants (fixed before any measurement; mirror the header + protocol). #
# --------------------------------------------------------------------------- #
GAIN_FEC_FILTER="${GAIN_FEC_FILTER:-fec,cols:16,rows:1,layout:even,arq:onreq}"
LOSSMAXTTL_FIXED=40
BASE_FREEZE=1; BASE_NAK=0; BASE_FEC_ON=0          # baseline B = Classic
RX_LATENCY_MS="${RX_LATENCY_MS:-1200}"
BITRATE_KBPS="${BITRATE_KBPS:-8000}"
NETEM_SEED_BASE="${NETEM_SEED_BASE:-1000}"
GAIN_STEADY_LOSS_PCT="${GAIN_STEADY_LOSS_PCT:-}"  # adverse axis (deep stage / smoke)

# Resolve the Rust fork sender exactly as reorder-stress.sh does (env or PATH).
SRTLA_SEND_RS_BIN="${SRTLA_SEND_RS_BIN:-}"
if [[ -z "$SRTLA_SEND_RS_BIN" ]] && command -v srtla_send_rs >/dev/null 2>&1; then
  SRTLA_SEND_RS_BIN="$(command -v srtla_send_rs)"
fi

# Build the FEC×NAK×FREEZE tuple list. Each entry is "freeze:nak:fecon"; the
# baseline tuple is skipped so CANDIDATES holds the 7 challengers.
CANDIDATES=()
build_candidates() {
  CANDIDATES=()
  local frz nak fec
  for frz in 1 0; do
    for nak in 0 1; do
      for fec in 0 1; do
        [[ "$frz" == "$BASE_FREEZE" && "$nak" == "$BASE_NAK" && "$fec" == "$BASE_FEC_ON" ]] && continue
        CANDIDATES+=("${frz}:${nak}:${fec}")
      done
    done
  done
}

# Falsifiability: REFUSE any tuple that would use arq:never, and require every FEC
# tuple to carry arq:onreq. Runs in EVERY mode (even --dry-run) so a banned recipe
# cannot be enumerated. GAIN_FEC_FILTER is the single FEC spec all FEC cells share.
assert_no_arq_never() {
  [[ "$GAIN_FEC_FILTER" == *arq:never* ]] && \
    die "REFUSED: GAIN_FEC_FILTER carries arq:never (pure FEC is BANNED; FEC must be arq:onreq)"
  [[ "$GAIN_FEC_FILTER" =~ ^fec, ]] || \
    die "REFUSED: GAIN_FEC_FILTER must start with 'fec,' (got '$GAIN_FEC_FILTER')"
  [[ "$GAIN_FEC_FILTER" == *arq:onreq* ]] || \
    die "REFUSED: FEC arms must be arq:onreq (GAIN_FEC_FILTER='$GAIN_FEC_FILTER' lacks it)"
}

# Human label + the SRTO tuple a cell drives reorder-stress.sh with.
cell_label()  { printf 'f%s-n%s-%s' "$1" "$2" "$([[ "$3" == 1 ]] && echo fec || echo plain)"; }
cell_filter() { [[ "$1" == 1 ]] && printf '%s' "$GAIN_FEC_FILTER" || printf ''; }
cell_srto()   { # freeze nak fecon
  local pf; pf="$([[ "$3" == 1 ]] && printf '%s' "$GAIN_FEC_FILTER" || printf '<none>')"
  printf 'REORDERFREEZE=%s NAKREPORT=%s LOSSMAXTTL=%s packetfilter=%s' \
    "$1" "$2" "$LOSSMAXTTL_FIXED" "$pf"
}

print_matrix() {
  build_candidates
  log "  axes: REORDERFREEZE in {1,0}  NAKREPORT in {0,1}  FEC in {off,on}  (LOSSMAXTTL=${LOSSMAXTTL_FIXED} held)"
  log "  FEC spec (arq:onreq hybrid; arq:never BANNED): ${GAIN_FEC_FILTER}"
  log "  baseline B: $(cell_srto "$BASE_FREEZE" "$BASE_NAK" "$BASE_FEC_ON")  [$(cell_label "$BASE_FREEZE" "$BASE_NAK" "$BASE_FEC_ON")]"
  log "  candidates (${#CANDIDATES[@]} = 2x2x2 - baseline):"
  local t frz nak fec
  for t in "${CANDIDATES[@]}"; do
    IFS=: read -r frz nak fec <<<"$t"
    log "    - $(cell_label "$frz" "$nak" "$fec")  ::  $(cell_srto "$frz" "$nak" "$fec")"
  done
}

# --------------------------------------------------------------------------- #
# CLI                                                                          #
# --------------------------------------------------------------------------- #
MODE="notice"
STAGE=""
CANDIDATE=""
BASELINE=""
DECISION_RULE=""
REPS="${REPS:-1}"
PHASE_SEC="${PHASE_SEC:-12}"
BUILD_DIR="${SRTLA_BUILD_DIR:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       MODE="dry-run"; shift ;;
    --smoke)         MODE="smoke"; shift ;;
    --stage)         MODE="stage"; STAGE="${2:?--stage needs screen|deep}"; shift 2 ;;
    --claim-gain)    MODE="claim-gain"; shift ;;
    --candidate)     CANDIDATE="${2:?--candidate needs a value}"; shift 2 ;;
    --baseline)      BASELINE="${2:?--baseline needs a value}"; shift 2 ;;
    --decision-rule) DECISION_RULE="${2:?--decision-rule needs a value}"; shift 2 ;;
    --reps)          REPS="${2:?--reps needs a value}"; shift 2 ;;
    --duration)      PHASE_SEC="${2:?--duration needs a value}"; shift 2 ;;
    --build-dir)     BUILD_DIR="${2:?--build-dir needs a value}"; shift 2 ;;
    -h|--help)       sed -n '2,110p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               die "unknown argument '$1' (try --help)" ;;
  esac
done
[[ "$REPS" =~ ^[0-9]+$ && "$REPS" -ge 1 ]] || die "--reps must be a positive integer"
[[ "$PHASE_SEC" =~ ^[0-9]+$ && "$PHASE_SEC" -ge 1 ]] || die "--duration must be a positive integer"

# Every mode self-checks the arq:never ban first — a banned recipe is never enumerated.
assert_no_arq_never

# --------------------------------------------------------------------------- #
# Run helpers (cloned from profile-validation-matrix.sh run_rep/run_cell): one  #
# reorder-stress rep per arm, alternating arm order per rep, shared per-rep seed #
# so both arms meet the same netem reorder draw (paired comparison).            #
# --------------------------------------------------------------------------- #
RUN_LOG=""

run_rep() { # out freeze nak fecon label seed
  local out="$1" frz="$2" nak="$3" fec="$4" label="$5" seed="$6"
  local -a env_kv=(
    "SRTLA_BUILD_DIR=${BUILD_DIR}"
    "SRTLA_SEND_RS_BIN=${SRTLA_SEND_RS_BIN}"
    "REQUIRE_RS_SENDER=1"
    "RX_LATENCY_MS=${RX_LATENCY_MS}"
    "BITRATE_KBPS=${BITRATE_KBPS}"
    "LOSSMAXTTL=${LOSSMAXTTL_FIXED}"
    "REORDERFREEZE=${frz}"
    "NAKREPORT=${nak}"
    "PROFILE_LABEL=${label}"
    "NETEM_SEED=${seed}"
  )
  [[ -n "$GAIN_STEADY_LOSS_PCT" ]] && env_kv+=("STEADY_LOSS_PCT=${GAIN_STEADY_LOSS_PCT}")
  if [[ "$fec" == 1 ]]; then
    env_kv+=("CALLER_PACKETFILTER=${GAIN_FEC_FILTER}" "SINK_EXTRA_ARGS=--packetfilter fec")
  fi
  rm -f "$REORDER_RESULT"
  env "${env_kv[@]}" bash "$REORDER" --duration "$PHASE_SEC" >>"$RUN_LOG" 2>&1
  local rc=$?
  if [[ -f "$REORDER_RESULT" ]]; then cp "$REORDER_RESULT" "$out"; else printf '{}\n' > "$out"; fi
  return "$rc"
}

run_cell() { # dir cand_freeze cand_nak cand_fecon cand_label
  local dir="$1" cf="$2" cn="$3" cfec="$4" clabel="$5"
  mkdir -p "${dir}/baseline" "${dir}/candidate"
  local r seed
  for (( r=1; r<=REPS; r++ )); do
    seed=$(( NETEM_SEED_BASE + r ))
    log "    [${clabel}] rep ${r}/${REPS} (seed ${seed})"
    if (( r % 2 == 1 )); then
      run_rep "${dir}/baseline/rep-${r}.json"  "$BASE_FREEZE" "$BASE_NAK" "$BASE_FEC_ON" "baseline-classic" "$seed" || true
      run_rep "${dir}/candidate/rep-${r}.json" "$cf" "$cn" "$cfec" "$clabel" "$seed" || true
    else
      run_rep "${dir}/candidate/rep-${r}.json" "$cf" "$cn" "$cfec" "$clabel" "$seed" || true
      run_rep "${dir}/baseline/rep-${r}.json"  "$BASE_FREEZE" "$BASE_NAK" "$BASE_FEC_ON" "baseline-classic" "$seed" || true
    fi
  done
}

# Capability + sender gate shared by smoke/stage. SKIP (exit 77) — never fabricate.
require_run_env() {
  if [[ -z "$SRTLA_SEND_RS_BIN" ]]; then
    log "SKIP gain-hunt-matrix: no srtla-send-rs resolvable (set SRTLA_SEND_RS_BIN or put"
    log "  srtla_send_rs on PATH). The campaign's PRIMARY sender is the Rust fork; refusing"
    log "  to measure the deprecated C srtla_send as production."
    exit 77
  fi
  if ! bash "$NETEM_LIB" require >/dev/null 2>&1; then
    log "SKIP gain-hunt-matrix: netem unavailable (need CAP_NET_ADMIN: root, sudo, or mapped-root userns)"
    exit 77
  fi
  resolve_build_dir
}

resolve_build_dir() {
  local d
  for d in "$BUILD_DIR" "${REPO_ROOT}/build" "/tmp/srtla-build"; do
    [[ -n "$d" ]] || continue
    if [[ -x "${d}/srtla_rec" && -x "${d}/tests/compat/srt-sink/srt-sink" ]]; then
      BUILD_DIR="$d"; return 0
    fi
  done
  die "no usable build dir (need srtla_rec + srt-sink). Build with:
   cmake -B build -DBUILD_COMPAT_TESTS=ON && cmake --build build -j"
}

# Print candidate-vs-baseline metrics for one finished cell (jq; no python needed).
summarize_cell() { # dir
  local dir="$1"
  command -v jq >/dev/null 2>&1 || { log "  (jq absent — skipping numeric summary)"; return 0; }
  local cf bf cg bg cwa bwa crwa brwa cdisc bdisc
  cf="$(ls "${dir}/candidate"/rep-*.json 2>/dev/null | head -1)"
  bf="$(ls "${dir}/baseline"/rep-*.json 2>/dev/null | head -1)"
  [[ -f "$cf" && -f "$bf" ]] || { log "  (no rep JSON produced)"; return 0; }
  cg="$(jq -r '.metrics.goodput_bps // 0' "$cf")";  bg="$(jq -r '.metrics.goodput_bps // 0' "$bf")"
  cwa="$(jq -r '.metrics.wire_amp // 0' "$cf")";    bwa="$(jq -r '.metrics.wire_amp // 0' "$bf")"
  crwa="$(jq -r '.metrics.reverse_wire_amp // 0' "$cf")"
  brwa="$(jq -r '.metrics.reverse_wire_amp // 0' "$bf")"
  cdisc="$(jq -r '.sink.disconnects // -1' "$cf")"; bdisc="$(jq -r '.sink.disconnects // -1' "$bf")"
  log ""
  log "  ---- cell metrics (candidate / baseline) ----"
  log "    goodput_bps      : ${cg} / ${bg}"
  log "    wire_amp         : ${cwa} / ${bwa}"
  log "    reverse_wire_amp : ${crwa} / ${brwa}"
  log "    disconnects      : ${cdisc} / ${bdisc}"
  # The deliverable is VISIBILITY: the reverse channel is now metered and resolves
  # the two recipes (B3/O1 — periodic-NAK's reverse cost is no longer invisible, so
  # a recipe cannot false-promote on forward amplification alone). The direction is
  # an empirical result, not an assertion: in this SRTLA topology the reverse
  # channel is dominated by per-packet broadcast ACKs, so NAK-OFF (which retransmits
  # more, lacking precise NAKs) often costs MORE reverse than NAK-ON.
  if awk -v c="$crwa" -v b="$brwa" 'BEGIN{exit !(c!=b)}'; then
    log "    -> reverse channel VISIBLE and distinguishes the recipes (candidate ${crwa} vs baseline ${brwa})."
    awk -v c="$crwa" -v b="$brwa" 'BEGIN{ printf "    -> NAK-on reverse cost is %s the NAK-off baseline (empirical).\n", (c>b?"ABOVE":"AT/BELOW") }' >&2
  else
    log "    NOTE: candidate and baseline reverse_wire_amp coincide (${crwa}); rerun with more reps/loss."
  fi
}

case "$MODE" in
  notice)
    log "gain-hunt-matrix: FEC×NAK×FREEZE gain-hunt orchestrator."
    log "  The operator-facing receiver-capability catalog ships EMPTY; a recipe is"
    log "  added ONLY after this campaign clears the pre-registered 'real gain + no"
    log "  regression' gate. See docs/GAIN-HUNT-PROTOCOL.md."
    log ""
    print_matrix
    log ""
    log "  modes:"
    log "    --dry-run     print the full 3-axis matrix + each cell's SRTO tuple"
    log "    --smoke       run ONE paired cell (needs CAP_NET_ADMIN + srtla-send-rs)"
    log "    --stage screen|deep   the full matrix / deep sweep (T-A6 seam)"
    log "    --help        the decision rule + candidate matrix in full"
    log "    --claim-gain  REFUSED until the campaign is run (falsifiable)"
    exit 0
    ;;

  dry-run)
    log "gain-hunt-matrix: DRY RUN — the FEC×NAK×FREEZE matrix (nothing is executed)."
    log ""
    print_matrix
    log ""
    log "  per candidate cell, the campaign drives scenarios/reorder-stress.sh paired/"
    log "  alternating (candidate vs baseline B), shared per-rep NETEM_SEED, collecting"
    log "  goodput_bps, pkt_rcv_drop, ts_sync_errors, ts_cc_errors, wire_amp,"
    log "  reverse_wire_amp, disconnects; then applies the §2 rule (Holm-Bonferroni)."
    log ""
    log "  sender: ${SRTLA_SEND_RS_BIN:-<unset — run modes will SKIP exit 77>} (srtla-send-rs, primary)"
    log "  deep stage (T-A6) adds: FEC geometry sweep + STEADY_LOSS_PCT/BURST_LOSS_PCT/RTT_SPREAD_MS axes."
    log "  protocol: ${PROTOCOL_DOC}"
    exit 0
    ;;

  smoke)
    require_run_env
    rm -rf "${RESULTS_DIR:?}/smoke"; mkdir -p "${RESULTS_DIR}/smoke"
    RUN_LOG="${RESULTS_DIR}/smoke/run.log"; : > "$RUN_LOG"
    # One NAK-axis cell: candidate (freeze1,nak1,fec-off) vs baseline (freeze1,nak0,
    # fec-off). Only NAK differs, so the reverse-channel metric isolates NAK's cost.
    # A little steady loss guarantees real NAK traffic on the reverse path.
    GAIN_STEADY_LOSS_PCT="${GAIN_STEADY_LOSS_PCT:-3}"
    log "================ gain-hunt-matrix --smoke ================"
    log "  build dir: ${BUILD_DIR} | sender: ${SRTLA_SEND_RS_BIN}"
    log "  reps=${REPS} phase=${PHASE_SEC}s bitrate=${BITRATE_KBPS}k steady_loss=${GAIN_STEADY_LOSS_PCT}%"
    log "  cell: candidate f1-n1-plain (NAK-on) vs baseline f1-n0-plain (Classic)"
    log "========================================================="
    run_cell "${RESULTS_DIR}/smoke/nak-on" 1 1 0 "smoke-freeze+nak-on"
    summarize_cell "${RESULTS_DIR}/smoke/nak-on"
    log ""
    log "  per-rep JSON: ${RESULTS_DIR}/smoke/nak-on/{candidate,baseline}/rep-*.json"
    log "  run log     : ${RUN_LOG}"
    # Smoke passes if both arms produced a result.json with metrics (instrument ran).
    cand="$(ls "${RESULTS_DIR}/smoke/nak-on/candidate"/rep-*.json 2>/dev/null | head -1)"
    base="$(ls "${RESULTS_DIR}/smoke/nak-on/baseline"/rep-*.json 2>/dev/null | head -1)"
    # Pass = paired result.json present, the Rust fork actually ran (sender_kind=rust),
    # and the NAK-on (candidate) run carries a NON-ZERO reverse_wire_bytes — the
    # reverse channel is metered and visible (the B3/O1 deliverable).
    if [[ -s "$cand" && -s "$base" ]] \
       && jq -e '.config.sender_kind == "rust"' "$cand" >/dev/null 2>&1 \
       && jq -e '.metrics.reverse_wire_amp != null' "$base" >/dev/null 2>&1 \
       && jq -e '(.metrics.reverse_wire_bytes // 0) > 0' "$cand" >/dev/null 2>&1; then
      log "SMOKE OK (reverse channel metered; sender=rust; reverse cost visible)"; exit 0
    fi
    log "SMOKE FAILED (missing paired result, non-rust sender, or zero reverse_wire_bytes on NAK-on)"; exit 1
    ;;

  stage)
    [[ "$STAGE" == "screen" || "$STAGE" == "deep" ]] || die "--stage must be screen|deep (got '$STAGE')"
    require_run_env
    rm -rf "${RESULTS_DIR:?}/${STAGE:?}"; mkdir -p "${RESULTS_DIR}/${STAGE}"
    RUN_LOG="${RESULTS_DIR}/${STAGE}/run.log"; : > "$RUN_LOG"
    build_candidates
    log "================ gain-hunt-matrix --stage ${STAGE} ================"
    log "  build dir: ${BUILD_DIR} | sender: ${SRTLA_SEND_RS_BIN}"
    log "  reps=${REPS} phase=${PHASE_SEC}s bitrate=${BITRATE_KBPS}k"
    if [[ "$STAGE" == "screen" ]]; then
      log "  SCREEN: all ${#CANDIDATES[@]} candidate cells vs baseline (no adverse axes)."
    else
      log "  DEEP: per-cell adverse sweep + FEC geometry + Holm-Bonferroni stats."
      log "  NOTE: the deep aggregation/stats layer is the T-A6 seam — this run only"
      log "  exercises the candidate cells; the cross-cell verdict is filled in later."
    fi
    log "==============================================================="
    local_t=0
    for t in "${CANDIDATES[@]}"; do
      IFS=: read -r frz nak fec <<<"$t"
      run_cell "${RESULTS_DIR}/${STAGE}/$(cell_label "$frz" "$nak" "$fec")" "$frz" "$nak" "$fec" "$(cell_label "$frz" "$nak" "$fec")"
      local_t=$(( local_t + 1 ))
    done
    log ""
    log "  ${local_t} candidate cells run. Per-rep JSON under ${RESULTS_DIR}/${STAGE}/."
    log "  Cross-cell verdict (§2 rule + Holm-Bonferroni) is the T-A6 deep-stats seam."
    exit 0
    ;;

  claim-gain)
    # Falsifiability anchor: a gain CANNOT be claimed by running this script. If the
    # required decision-rule inputs are missing, say which; if present, still refuse
    # because no aggregated campaign verdict is produced here (the §2 stats are T-A6).
    missing=()
    [[ -n "$CANDIDATE" ]]      || missing+=("--candidate <id>")
    [[ -n "$BASELINE" ]]       || missing+=("--baseline <result.json>")
    [[ -n "$DECISION_RULE" ]]  || missing+=("--decision-rule <rule.json>")
    if [[ ${#missing[@]} -gt 0 ]]; then
      log "gain-hunt-matrix: REFUSED to claim a gain — missing required inputs:"
      for m in "${missing[@]}"; do log "    ${m}"; done
      log "  A gain claim requires the candidate id, the paired baseline evidence,"
      log "  and the pre-registered decision rule. See docs/GAIN-HUNT-PROTOCOL.md."
      exit 3
    fi
    log "gain-hunt-matrix: REFUSED to claim a gain for candidate '${CANDIDATE}'."
    log "  This driver runs the screen cells but does NOT compute the cross-cell"
    log "  'real gain + no regression' verdict (the Holm-Bonferroni stats layer is the"
    log "  T-A6 deep-stage seam). A gain may be asserted ONLY by that aggregation over"
    log "  measured paired evidence — never by invoking this script. Run --stage deep"
    log "  under CAP_NET_ADMIN and let the stats layer decide before adding any recipe."
    exit 3
    ;;
esac

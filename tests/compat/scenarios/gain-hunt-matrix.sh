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
#   gain-hunt-matrix.sh --analyze <p>   apply the pre-registered §2 decision-rule
#                                       statistics to ALREADY-MEASURED paired evidence
#                                       <p> (a self-contained fixture JSON, or a dir of
#                                       <cell>/{candidate,baseline}/rep-*.json). Exact
#                                       Mann-Whitney U (stdlib-only, no scipy) + Holm-
#                                       Bonferroni across every cell; emits a verdict
#                                       JSON to stdout. This is the §2 stats layer the
#                                       deep stage calls — it COMPUTES a verdict over
#                                       supplied evidence, it does not RUN the campaign.
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
ANALYZE_PATH=""
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
    --analyze)       MODE="analyze"; ANALYZE_PATH="${2:?--analyze needs a path}"; shift 2 ;;
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
    log "    --analyze <p> apply the §2 decision-rule stats (exact Mann-Whitney U,"
    log "                  Holm-Bonferroni) to measured paired evidence -> verdict JSON"
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

  analyze)
    # §2 decision-rule statistics over ALREADY-MEASURED paired evidence. This COMPUTES
    # a verdict from supplied per-rep results — it does not run the campaign, needs no
    # CAP_NET_ADMIN and no sender, and is stdlib-only (scipy is absent on this box).
    [[ -e "$ANALYZE_PATH" ]] || die "--analyze: path not found: ${ANALYZE_PATH}"
    python3 - "$ANALYZE_PATH" <<'PY'
import json, math, os, sys, glob
from collections import Counter

ALPHA = 0.05
GAIN_GOODPUT_RATIO = 1.03   # real gain: median goodput(C) >= 1.03x median goodput(B)
GAIN_LATEDROP_RATIO = 0.80  # real gain: median pkt_rcv_drop(C) <= 0.80x median(B)
GOODPUT_FLOOR = 0.99        # no-regression + late-drop-win non-inferiority floor
WIRE_AMP_CEIL = 1.10
REVERSE_AMP_CEIL = 1.10

def median(xs):
    xs = sorted(xs); n = len(xs)
    if n == 0:
        return 0.0
    mid = n // 2
    return float(xs[mid]) if n % 2 else (xs[mid - 1] + xs[mid]) / 2.0

def p95(xs):
    xs = sorted(xs); n = len(xs)
    if n == 0:
        return 0.0
    idx = min(n - 1, max(0, math.ceil(0.95 * n) - 1))
    return float(xs[idx])

def midranks(values):
    # 1-based ranks with ties resolved to the average rank (midrank) of the tie group.
    order = sorted(range(len(values)), key=lambda i: values[i])
    ranks = [0.0] * len(values)
    n = len(values); i = 0
    while i < n:
        j = i
        while j + 1 < n and values[order[j + 1]] == values[order[i]]:
            j += 1
        avg = (i + j + 2) / 2.0
        for k in range(i, j + 1):
            ranks[order[k]] = avg
        i = j + 1
    return ranks

def _comb(a, b):
    return math.comb(a, b)

def mann_whitney_u_exact(x, y):
    """Exact Mann-Whitney U statistic and two-sided p-value for small n.

    Uses the exact permutation rank-sum distribution for m,n <= 20: a subset-sum
    DP over the (doubled, tie-aware) ranks counts, for every way to assign m of the
    m+n ranks to x, the resulting rank sum, giving the exact null distribution of U.
    Two-sided p = P(U <= min(U, m*n - U)) * 2 (clamped to 1). For m or n > 20 it
    falls back to the normal approximation with tie correction (reserved for future
    deeper sweeps; the campaign's n=10 always takes the exact path). Returns (U, p)
    with U the candidate-arm statistic.
    """
    m = len(x); n = len(y)
    if m == 0 or n == 0:
        return 0.0, 1.0
    combined = list(x) + list(y)
    ranks = midranks(combined)
    if m > 20 or n > 20:
        return _mann_whitney_u_normal(m, n, ranks, combined)
    # Double the midranks so every value is an integer (midranks are k/2 multiples).
    dr = [int(round(2 * r)) for r in ranks]
    Rx2 = sum(dr[:m])
    Ux2 = Rx2 - m * (m + 1)            # doubled U for the candidate arm
    Uy2 = 2 * m * n - Ux2
    Umin2 = min(Ux2, Uy2)
    Ux = Ux2 / 2.0
    total_sum = sum(dr)
    # dp[k][s] = number of size-k rank subsets summing to s (doubled units).
    dp = [[0] * (total_sum + 1) for _ in range(m + 1)]
    dp[0][0] = 1
    for r in dr:
        for k in range(m, 0, -1):
            row_k = dp[k]; row_k1 = dp[k - 1]
            for s in range(total_sum, r - 1, -1):
                c = row_k1[s - r]
                if c:
                    row_k[s] += c
    total = _comb(m + n, m)
    # U <= Umin  <=>  R2 <= Umin2 + m(m+1)
    thr = Umin2 + m * (m + 1)
    count = sum(dp[m][s] for s in range(0, min(thr, total_sum) + 1))
    p = min(1.0, 2.0 * count / total)
    return Ux, p

def _mann_whitney_u_normal(m, n, ranks, combined):
    N = m + n
    Rx = sum(ranks[:m])
    Ux = Rx - m * (m + 1) / 2.0
    mu = m * n / 2.0
    tie = sum(t ** 3 - t for t in Counter(combined).values())
    var = (m * n / 12.0) * ((N + 1) - tie / (N * (N - 1.0)))
    if var <= 0:
        return Ux, 1.0
    z = (abs(Ux - mu) - 0.5) / math.sqrt(var)
    if z < 0:
        z = 0.0
    p = 2.0 * (1.0 - 0.5 * (1.0 + math.erf(z / math.sqrt(2.0))))
    return Ux, min(1.0, p)

def rep_field(d, key, default):
    if key in d:
        return d[key]
    m = d.get("metrics") or {}
    if key in m:
        return m[key]
    s = d.get("sink") or {}
    if key in s:
        return s[key]
    return default

def norm_rep(d):
    return {
        "goodput_bps": float(rep_field(d, "goodput_bps", 0) or 0),
        "pkt_rcv_drop": float(rep_field(d, "pkt_rcv_drop", 0) or 0),
        "ts_sync_errors": int(rep_field(d, "ts_sync_errors", 0) or 0),
        "ts_cc_errors": int(rep_field(d, "ts_cc_errors", 0) or 0),
        "wire_amp": float(rep_field(d, "wire_amp", 0) or 0),
        "reverse_wire_amp": float(rep_field(d, "reverse_wire_amp", 0) or 0),
        "disconnects": int(rep_field(d, "disconnects", 0) or 0),
    }

def load_reps_dir(d):
    out = []
    for f in sorted(glob.glob(os.path.join(d, "rep-*.json"))):
        try:
            with open(f) as fh:
                out.append(norm_rep(json.load(fh)))
        except (OSError, ValueError):
            out.append(norm_rep({}))
    return out

def load_cells(path):
    if os.path.isfile(path):
        with open(path) as fh:
            doc = json.load(fh)
        cid = doc.get("candidate_id", "candidate")
        if "cells" in doc:
            cells = {name: {"candidate": [norm_rep(r) for r in c.get("candidate", [])],
                            "baseline":  [norm_rep(r) for r in c.get("baseline", [])]}
                     for name, c in doc["cells"].items()}
        else:
            cells = {"cell": {"candidate": [norm_rep(r) for r in doc.get("candidate", [])],
                              "baseline":  [norm_rep(r) for r in doc.get("baseline", [])]}}
        return cid, cells
    cand = os.path.join(path, "candidate"); base = os.path.join(path, "baseline")
    if os.path.isdir(cand) and os.path.isdir(base):
        return os.path.basename(os.path.normpath(path)) or "candidate", \
            {"cell": {"candidate": load_reps_dir(cand), "baseline": load_reps_dir(base)}}
    cells = {}
    for name in sorted(os.listdir(path)):
        sub = os.path.join(path, name)
        if os.path.isdir(os.path.join(sub, "candidate")) and os.path.isdir(os.path.join(sub, "baseline")):
            cells[name] = {"candidate": load_reps_dir(os.path.join(sub, "candidate")),
                           "baseline":  load_reps_dir(os.path.join(sub, "baseline"))}
    return "candidate", cells

def analyze_cell(arms):
    C = arms["candidate"]; B = arms["baseline"]
    cg = [r["goodput_bps"] for r in C]; bg = [r["goodput_bps"] for r in B]
    cd = [r["pkt_rcv_drop"] for r in C]; bd = [r["pkt_rcv_drop"] for r in B]
    mcg = median(cg); mbg = median(bg)
    mcd = median(cd); mbd = median(bd)
    goodput_win = mbg > 0 and mcg >= GAIN_GOODPUT_RATIO * mbg
    latedrop_win = (mbd > 0 and mcd <= GAIN_LATEDROP_RATIO * mbd
                    and (mbg <= 0 or mcg >= GOODPUT_FLOOR * mbg))
    if goodput_win:
        win_metric = "goodput_bps"; U, p = mann_whitney_u_exact(cg, bg)
    elif latedrop_win:
        win_metric = "pkt_rcv_drop"; U, p = mann_whitney_u_exact(cd, bd)
    else:
        win_metric = "goodput_bps"; U, p = mann_whitney_u_exact(cg, bg)
    win = goodput_win or latedrop_win

    mc_wire = median([r["wire_amp"] for r in C]); mb_wire = median([r["wire_amp"] for r in B])
    mc_rev = median([r["reverse_wire_amp"] for r in C]); mb_rev = median([r["reverse_wire_amp"] for r in B])
    g = {
        "disconnects_zero": all(r["disconnects"] == 0 for r in C),
        "ts_sync_zero": all(r["ts_sync_errors"] == 0 for r in C),
        "ts_cc_le_baseline": median([r["ts_cc_errors"] for r in C]) <= median([r["ts_cc_errors"] for r in B]),
        "goodput_ge_99pct": mcg >= GOODPUT_FLOOR * mbg if mbg > 0 else True,
        "wire_amp_le_110pct": (mc_wire <= WIRE_AMP_CEIL * mb_wire) if mb_wire > 0 else (mc_wire == 0),
        "reverse_wire_amp_le_110pct": (mc_rev <= REVERSE_AMP_CEIL * mb_rev) if mb_rev > 0 else (mc_rev == 0),
        "p95_late_drop_le_baseline": p95(cd) <= p95(bd),
    }
    tripped = [k for k, ok in g.items() if not ok]
    return {
        "n_candidate": len(C), "n_baseline": len(B),
        "gain": {"goodput": goodput_win, "late_drop": latedrop_win, "win": win,
                 "win_metric": win_metric},
        "mwu": {"metric": win_metric, "U": U, "p": p},
        "guardrails": g, "tripped_guardrails": tripped,
        "no_regression": not tripped,
        "medians": {"goodput_c": mcg, "goodput_b": mbg, "pkt_rcv_drop_c": mcd,
                    "pkt_rcv_drop_b": mbd, "wire_amp_c": mc_wire, "wire_amp_b": mb_wire,
                    "reverse_wire_amp_c": mc_rev, "reverse_wire_amp_b": mb_rev},
    }

def holm(pmap):
    # Holm-Bonferroni step-down over the WHOLE family (every cell in the set).
    order = sorted(pmap.items(), key=lambda kv: kv[1])
    k = len(order); adj = {}; running = 0.0
    for i, (name, p) in enumerate(order):
        running = max(running, (k - i) * p)
        adj[name] = min(1.0, running)
    return adj

path = sys.argv[1]
candidate_id, cells = load_cells(path)
if not cells or all((not c["candidate"] or not c["baseline"]) for c in cells.values()):
    sys.stderr.write("gain-hunt-matrix --analyze: no paired evidence found at %s\n" % path)
    print(json.dumps({"verdict": "error", "promoted": False, "winner": "none",
                      "reason": "no_paired_evidence", "path": path}))
    sys.exit(2)

cell_results = {name: analyze_cell(arms) for name, arms in cells.items()}
pmap = {name: r["mwu"]["p"] for name, r in cell_results.items()}
adj = holm(pmap)
for name, r in cell_results.items():
    r["holm_adjusted_p"] = adj[name]
    r["holm_significant"] = adj[name] < ALPHA

real_gain_cells = [name for name, r in cell_results.items()
                   if r["gain"]["win"] and r["holm_significant"] and r["no_regression"]]
all_no_regression = all(r["no_regression"] for r in cell_results.values())
promoted = bool(real_gain_cells) and all_no_regression

if promoted:
    reason = "real_gain_in_%d_cell(s)_no_regression" % len(real_gain_cells)
elif not all_no_regression:
    reason = "regression_in_>=1_cell"
elif not any(r["gain"]["win"] for r in cell_results.values()):
    reason = "no_real_gain"
else:
    reason = "gain_not_significant_after_holm"

regression_cells = {name: r["tripped_guardrails"]
                    for name, r in cell_results.items() if r["tripped_guardrails"]}

verdict = {
    "candidate_id": candidate_id,
    "verdict": "promoted" if promoted else "not_promoted",
    "promoted": promoted,
    "winner": candidate_id if promoted else "none",
    "reason": reason,
    "alpha": ALPHA,
    "n_cells": len(cell_results),
    "real_gain_cells": real_gain_cells,
    "regression_cells": regression_cells,
    "holm_adjusted_p": adj,
    "cells": cell_results,
}
print(json.dumps(verdict, indent=2, sort_keys=True))

sys.stderr.write("\n========== gain-hunt --analyze (%s) ==========\n" % candidate_id)
for name in sorted(cell_results):
    r = cell_results[name]
    sys.stderr.write(
        "  %-18s win=%-5s U=%.1f p=%.3e holm=%.3e no_regr=%-5s tripped=%s\n" % (
            name, str(r["gain"]["win"]), r["mwu"]["U"], r["mwu"]["p"],
            r["holm_adjusted_p"], str(r["no_regression"]),
            ",".join(r["tripped_guardrails"]) or "-"))
sys.stderr.write("VERDICT: %s (winner=%s; %s)\n" % (
    verdict["verdict"], verdict["winner"], reason))
sys.stderr.write("================================================\n")
sys.exit(0 if promoted else 1)
PY
    exit $?
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

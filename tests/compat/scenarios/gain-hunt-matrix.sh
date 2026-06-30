#!/usr/bin/env bash
#
# gain-hunt-matrix.sh — ORCHESTRATOR STUB for the FEC-mixture gain hunt (R&D).
#
# WHAT THIS IS: the documented, falsifiable skeleton of the campaign that decides
# whether any FEC packet-filter mixture earns a place in the operator-facing
# receiver-capability catalog. The catalog ships EMPTY; a mixture is added ONLY
# after this campaign produces evidence that clears the pre-registered gate below.
# This script DOES NOT run that campaign — it is a scaffold (R&D track). It exists
# to (1) fix the decision rule in code before any data is collected, (2) enumerate
# the candidate-mixture matrix, and (3) refuse — loudly and non-zero — to "claim a
# gain" until the campaign is wired and its required inputs are supplied. The full
# protocol lives in docs/GAIN-HUNT-PROTOCOL.md; this header is the executable echo
# of it.
#
# ===================== PRE-REGISTERED DECISION RULE =========================
# "real gain + no regression" — fixed HERE, before any measurement exists. A
# candidate mixture C beats the BellaBox-parity baseline B (Classic L2 + latency,
# ARQ always on; see docs/RECEIVER-RECONCILIATION.md) on a per-cell basis ONLY if
# BOTH halves hold across the adverse-config matrix, paired/alternating, shared
# per-rep netem seed, with a Holm-Bonferroni correction across cells:
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
#     * wire_amp(C) <= 1.10 x wire_amp(B) (FEC overhead is bounded — the whole point
#       of arq:onreq over pure FEC is to pay parity bytes only when they buy a gain).
#     * p95 pkt_rcv_drop(C) <= p95 pkt_rcv_drop(B) (no tail-latency regression).
#
#   VERDICT: a mixture earns its catalog button ONLY if it shows REAL GAIN in at
#   least one adverse cell AND NO REGRESSION in EVERY cell. A gain in one cell
#   bought by a regression in another is NOT a win. Ties and "equal" outcomes keep
#   the baseline (catalog stays empty) — the burden of proof is on the candidate.
# ============================================================================
#
# ===================== CANDIDATE-MIXTURE MATRIX =============================
# FEC is ALWAYS hybrid: arq:onreq (FEC parity + ARQ retransmit on demand). Pure
# FEC (arq:never) is BANNED — it trades latency for bytes with no ARQ floor and
# regressed on every prior informal trial; it is not a candidate and MUST NOT be
# added here. Candidates vary the SRT packet-filter geometry only:
#
#   id            packetfilter spec (caller side)                       arq
#   --            --------------------------------------------------    -------
#   m-even-8x8    fec,cols:8,rows:8,layout:even                         onreq
#   m-even-10x10  fec,cols:10,rows:10,layout:even                       onreq
#   m-stair-8x8   fec,cols:8,rows:8,layout:staircase                    onreq
#   m-stair-12x6  fec,cols:12,rows:6,layout:staircase                   onreq
#   m-cols-only   fec,cols:10,rows:1,layout:even   (column-only parity) onreq
#   (baseline)    <no packet filter — Classic L2 + latency, ARQ only>   n/a
#
# Each candidate is swept across the adverse-config axes (see the matrix table in
# docs/GAIN-HUNT-PROTOCOL.md), driving scenarios/reorder-stress.sh with:
#   STEADY_LOSS_PCT  in {0, 1, 3, 7}        (uniform link loss %)
#   BURST_LOSS_PCT   in {0, 20}             (Gilbert-Elliott / correlation burst)
#   RTT_SPREAD_MS    in {0, 150, 400}       (extra slow-link delay)
# A "cell" is one (candidate, steady, burst, rtt) point; the baseline is measured
# in the SAME cell. arq:never appears in the matrix ONLY as a banned-control row
# the campaign asserts it never promotes — never as a catalog candidate.
# ============================================================================
#
# WHY A STUB: the gain hunt is open-ended R&D — building and pinning each FEC
# libsrt geometry, running N reps x M cells x K candidates, and doing the stats is
# a campaign, not a PR gate. Wiring it is deferred. Until then this script is the
# contract: it is registered in matrix.yaml as `tier: informational` (NON-blocking)
# so it never gates CI, and it is falsifiable — it will not emit a "gain" verdict
# without the decision-rule inputs the protocol demands.
#
# Usage:
#   gain-hunt-matrix.sh                 print this notice + matrix summary (exit 0)
#   gain-hunt-matrix.sh --dry-run       print the full planned campaign (exit 0)
#   gain-hunt-matrix.sh --help          this header (exit 0)
#   gain-hunt-matrix.sh --claim-gain \  attempt to assert a candidate gain. REFUSED
#       --candidate <id> \              (exit 3) — the campaign is unimplemented and
#       --baseline <result.json> \      no measured evidence exists. Even WITH all
#       --decision-rule <rule.json>     inputs the stub refuses; without them it
#                                       lists what is missing. This is the
#                                       falsifiability anchor: a gain cannot be
#                                       claimed by running this script.
#
# Rule D: writes nothing above the srtla repo root (the stub writes nothing at all).
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROTOCOL_DOC="${SCRIPT_DIR}/../../../docs/GAIN-HUNT-PROTOCOL.md"

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'gain-hunt-matrix: %s\n' "$*" >&2; exit 2; }

# Candidate ids and adverse axes (mirrors the header matrix + the protocol doc).
CANDIDATES=(m-even-8x8 m-even-10x10 m-stair-8x8 m-stair-12x6 m-cols-only)
STEADY_LOSS_GRID=(0 1 3 7)
BURST_LOSS_GRID=(0 20)
RTT_SPREAD_GRID=(0 150 400)

# --------------------------------------------------------------------------- #
# CLI                                                                          #
# --------------------------------------------------------------------------- #
MODE="notice"
CANDIDATE=""
BASELINE=""
DECISION_RULE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       MODE="dry-run"; shift ;;
    --claim-gain)    MODE="claim-gain"; shift ;;
    --candidate)     CANDIDATE="${2:?--candidate needs a value}"; shift 2 ;;
    --baseline)      BASELINE="${2:?--baseline needs a value}"; shift 2 ;;
    --decision-rule) DECISION_RULE="${2:?--decision-rule needs a value}"; shift 2 ;;
    -h|--help)       sed -n '2,95p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               die "unknown argument '$1' (try --help)" ;;
  esac
done

print_matrix() {
  log "  candidate mixtures (FEC always arq:onreq; arq:never is BANNED):"
  local c
  for c in "${CANDIDATES[@]}"; do log "    - ${c}"; done
  log "  adverse-config axes (drive scenarios/reorder-stress.sh):"
  log "    STEADY_LOSS_PCT in {${STEADY_LOSS_GRID[*]}}"
  log "    BURST_LOSS_PCT  in {${BURST_LOSS_GRID[*]}}"
  log "    RTT_SPREAD_MS   in {${RTT_SPREAD_GRID[*]}}"
  local cells=$(( ${#CANDIDATES[@]} * ${#STEADY_LOSS_GRID[@]} * ${#BURST_LOSS_GRID[@]} * ${#RTT_SPREAD_GRID[@]} ))
  log "  matrix size: ${#CANDIDATES[@]} candidates x ${#STEADY_LOSS_GRID[@]} x ${#BURST_LOSS_GRID[@]} x ${#RTT_SPREAD_GRID[@]} = ${cells} candidate-cells (+ paired baseline per cell)"
}

case "$MODE" in
  notice)
    log "gain-hunt-matrix: R&D ORCHESTRATOR STUB — the campaign is NOT wired."
    log "  The operator-facing receiver-capability catalog ships EMPTY; a FEC"
    log "  mixture is added ONLY after this campaign clears the pre-registered"
    log "  'real gain + no regression' gate. See docs/GAIN-HUNT-PROTOCOL.md."
    log ""
    print_matrix
    log ""
    log "  This stub runs no measurement and claims no gain. Next steps:"
    log "    --dry-run     print the full planned campaign"
    log "    --help        the decision rule + candidate matrix in full"
    log "    --claim-gain  REFUSED until the campaign is implemented (falsifiable)"
    exit 0
    ;;

  dry-run)
    log "gain-hunt-matrix: DRY RUN — planned campaign (nothing is executed)."
    log ""
    print_matrix
    log ""
    log "  per cell, the campaign WOULD:"
    log "    1. build/pin the candidate's FEC libsrt geometry (arq:onreq)"
    log "    2. run scenarios/reorder-stress.sh paired/alternating (candidate vs"
    log "       BellaBox-parity baseline), shared per-rep NETEM_SEED, N reps each"
    log "    3. collect goodput_bps, pkt_rcv_drop, ts_*_errors, wire_amp, disconnects"
    log "    4. apply the pre-registered 'real gain + no regression' rule with a"
    log "       Holm-Bonferroni correction across cells (see header / protocol doc)"
    log ""
    log "  VERDICT POLICY: a mixture earns a catalog button ONLY with REAL GAIN in"
    log "  >=1 cell AND NO REGRESSION in EVERY cell. Ties keep the baseline."
    log "  arq:never (pure FEC) is a banned control row, never a catalog candidate."
    log ""
    log "  protocol: ${PROTOCOL_DOC}"
    log "  NOTE: campaign execution is intentionally NOT implemented (R&D track)."
    exit 0
    ;;

  claim-gain)
    # Falsifiability anchor: a gain CANNOT be claimed by running this stub. If the
    # required decision-rule inputs are missing, say which; if present, still refuse
    # because no measured evidence exists (the campaign is unimplemented).
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
    log "  Inputs were supplied, but the gain-hunt campaign is an UNIMPLEMENTED"
    log "  R&D track: this stub holds no measured candidate-vs-baseline evidence,"
    log "  so the 'real gain + no regression' rule cannot be evaluated and NO gain"
    log "  may be asserted. Wire the campaign (docs/GAIN-HUNT-PROTOCOL.md) and run"
    log "  it under CAP_NET_ADMIN before any mixture is added to the catalog."
    exit 3
    ;;
esac

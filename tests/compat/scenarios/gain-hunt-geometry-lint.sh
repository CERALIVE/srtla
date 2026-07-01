#!/usr/bin/env bash
#
# gain-hunt-geometry-lint.sh — pre-registered FEC-geometry / wire-amp budget guard.
#
# WHAT THIS IS: the executable form of the §3 geometry constraint (Oracle O5). The
# gain hunt fixes ONE FEC geometry for the screen matrix — column-only parity
# `fec,cols:16,rows:1,layout:even,arq:onreq` — and pre-registers `cols≥16` so the
# forward FEC overhead stays clear of the §2 `wire_amp ≤ 1.10×` budget BY
# CONSTRUCTION. Column-parity overhead is `1/cols`, so:
#
#     cols:16  ⇒ 6.25%   clear headroom under the 10% budget   (PASS)
#     cols:10  ⇒ 10.0%    exactly on the cliff, no headroom      (REJECT)
#     cols:8   ⇒ 12.5%    exceeds the budget by construction     (REJECT)
#
# This lint (a) reads the orchestrator's ACTIVE GAIN_FEC_FILTER default and asserts
# its geometry is promotable (cols≥16 AND overhead < budget), so a regression that
# narrows the geometry to cols:8/10 trips CI here, not in a privileged campaign run;
# and (b) runs a self-test discrimination table proving the budget check actually
# DISCRIMINATES (cols:16 passes, cols:10/8 reject) — a falsifiable check, not a
# rubber stamp. Pure stdlib: no scipy, no netem, no sender — runs anywhere awk does.
#
# Exit 0 = active geometry promotable AND discrimination table correct;
# exit 1 = active geometry exceeds budget / below cols floor, or table mismatch;
# exit 2 = setup error (orchestrator or geometry spec not found).
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ORCH="${SCRIPT_DIR}/gain-hunt-matrix.sh"

# §2 forward-overhead budget: wire_amp ≤ 1.10× ⇒ FEC overhead ≤ 0.10. "Clear
# headroom" (the cols≥16 pre-registration) means strictly UNDER the cliff, so the
# active geometry must satisfy overhead < BUDGET; cols:10 sitting exactly ON 0.10 is
# rejected as "no headroom".
BUDGET="0.10"
COLS_FLOOR=16

[[ -f "$ORCH" ]] || { echo "missing orchestrator: $ORCH" >&2; exit 2; }

# Pull the orchestrator's active FEC geometry (the single spec every FEC cell shares).
active_spec="$(awk -F'"' '/^GAIN_FEC_FILTER=/{print $2; exit}' "$ORCH")"
# Strip the `${GAIN_FEC_FILTER:-...}` wrapper, keeping the default literal.
active_spec="${active_spec#\$\{GAIN_FEC_FILTER:-}"
active_spec="${active_spec%\}}"
[[ -n "$active_spec" && "$active_spec" == fec,* ]] || {
  echo "could not parse GAIN_FEC_FILTER default from $ORCH (got '${active_spec}')" >&2
  exit 2
}

# cols:<n> from a `fec,…,cols:<n>,…` spec.
cols_of() { sed -n 's/.*cols:\([0-9]\+\).*/\1/p' <<<"$1"; }

# Verdict for a geometry: PASS iff cols≥FLOOR AND 1/cols < BUDGET; else REJECT.
geometry_verdict() {
  local spec="$1" cols
  cols="$(cols_of "$spec")"
  [[ -n "$cols" && "$cols" -gt 0 ]] || { echo "REJECT"; return; }
  awk -v c="$cols" -v floor="$COLS_FLOOR" -v budget="$BUDGET" 'BEGIN{
    ovh = 1.0 / c
    if (c >= floor && ovh < budget) print "PASS"; else print "REJECT"
  }'
}

overhead_pct() { awk -v c="$1" 'BEGIN{ printf "%.4g", 100.0/c }'; }

fail=0

# ---- (a) the ACTIVE orchestrator geometry must be promotable -------------------
acols="$(cols_of "$active_spec")"
averdict="$(geometry_verdict "$active_spec")"
if [[ "$averdict" == "PASS" ]]; then
  echo "PASS active geometry '${active_spec}': cols=${acols} ⇒ $(overhead_pct "$acols")% overhead (< ${BUDGET}, cols≥${COLS_FLOOR})"
else
  echo "FAIL active geometry '${active_spec}': cols=${acols:-?} ⇒ $(overhead_pct "${acols:-1}")% overhead violates cols≥${COLS_FLOOR} / wire_amp ≤1.10× budget" >&2
  fail=1
fi

# ---- (b) discrimination self-test (proves the check is falsifiable) ------------
# spec|expected-verdict — cols:16 PASS, cols:10 REJECT (cliff), cols:8 REJECT (over).
while IFS='|' read -r spec want; do
  [[ -z "$spec" ]] && continue
  got="$(geometry_verdict "$spec")"
  cols="$(cols_of "$spec")"
  if [[ "$got" == "$want" ]]; then
    echo "PASS table ${spec}: $(overhead_pct "$cols")% ⇒ ${got}"
  else
    echo "FAIL table ${spec}: $(overhead_pct "$cols")% got ${got} want ${want}" >&2
    fail=1
  fi
done <<'TABLE'
fec,cols:16,rows:1,layout:even,arq:onreq|PASS
fec,cols:10,rows:1,layout:even,arq:onreq|REJECT
fec,cols:8,rows:1,layout:even,arq:onreq|REJECT
TABLE

if [[ "$fail" -eq 0 ]]; then
  echo "gain-hunt-geometry-lint: active geometry within budget; discrimination table correct"
  exit 0
fi
echo "gain-hunt-geometry-lint: FAILURES (see above)" >&2
exit 1

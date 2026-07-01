#!/usr/bin/env bash
#
# gain-hunt-analyze-test.sh — golden-fixture test for gain-hunt-matrix.sh --analyze.
#
# Runs the §2 decision-rule analyzer over the committed golden fixtures and asserts
# its verdict JSON matches fixtures/gain-hunt-golden/expected.json — including the
# EXACT Mann-Whitney U statistic and the Holm-corrected p-value computed by hand
# (p_clean = 2 / C(20,10) when all 10 candidate goodput samples beat all 10 baseline
# samples). Pure stdlib: no scipy, no netem, no sender — runs anywhere python3 does.
#
# Exit 0 = every fixture matched expected.json; exit 1 = a mismatch; exit 2 = setup error.
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ORCH="${SCRIPT_DIR}/gain-hunt-matrix.sh"
FIXDIR="${SCRIPT_DIR}/../fixtures/gain-hunt-golden"
EXPECTED="${FIXDIR}/expected.json"

[[ -x "$ORCH" || -f "$ORCH" ]] || { echo "missing orchestrator: $ORCH" >&2; exit 2; }
[[ -f "$EXPECTED" ]] || { echo "missing expected.json: $EXPECTED" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
for fx in gain regression reverse-spam tie; do
  fixture="${FIXDIR}/${fx}-fixture.json"
  [[ -f "$fixture" ]] || { echo "FAIL ${fx}: fixture not found ($fixture)" >&2; fail=1; continue; }
  bash "$ORCH" --analyze "$fixture" >"${TMP}/actual.json" 2>/dev/null
  if ! python3 - "$EXPECTED" "${fx}-fixture.json" "${TMP}/actual.json" <<'PY'
import json, math, sys
expected_path, key, actual_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(actual_path) as fh:
    actual = json.load(fh)
with open(expected_path) as fh:
    exp = json.load(fh)[key]

RELTOL = 1e-9
errs = []
def near(a, b):
    return abs(a - b) <= RELTOL + RELTOL * abs(b)

for f in ("verdict", "promoted", "winner", "reason"):
    if actual.get(f) != exp.get(f):
        errs.append("%s: got %r want %r" % (f, actual.get(f), exp.get(f)))

if sorted(actual.get("real_gain_cells", [])) != sorted(exp.get("real_gain_cells", [])):
    errs.append("real_gain_cells: got %r want %r"
                % (actual.get("real_gain_cells"), exp.get("real_gain_cells")))

if actual.get("regression_cells", {}) != exp.get("regression_cells", {}):
    errs.append("regression_cells: got %r want %r"
                % (actual.get("regression_cells"), exp.get("regression_cells")))

for cell, ec in exp.get("cells", {}).items():
    ac = actual.get("cells", {}).get(cell)
    if ac is None:
        errs.append("cell %s missing in actual" % cell); continue
    if not near(ac["mwu"]["U"], ec["U"]):
        errs.append("cell %s U: got %r want %r" % (cell, ac["mwu"]["U"], ec["U"]))
    if not near(ac["mwu"]["p"], ec["p"]):
        errs.append("cell %s p: got %r want %r" % (cell, ac["mwu"]["p"], ec["p"]))
    if not near(ac["holm_adjusted_p"], ec["holm_adjusted_p"]):
        errs.append("cell %s holm_p: got %r want %r"
                    % (cell, ac["holm_adjusted_p"], ec["holm_adjusted_p"]))
    if ac["no_regression"] != ec["no_regression"]:
        errs.append("cell %s no_regression: got %r want %r"
                    % (cell, ac["no_regression"], ec["no_regression"]))
    if ac["gain"]["win"] != ec["gain_win"]:
        errs.append("cell %s gain_win: got %r want %r"
                    % (cell, ac["gain"]["win"], ec["gain_win"]))
    if "tripped_guardrails" in ec and ac["tripped_guardrails"] != ec["tripped_guardrails"]:
        errs.append("cell %s tripped: got %r want %r"
                    % (cell, ac["tripped_guardrails"], ec["tripped_guardrails"]))

if errs:
    for e in errs:
        sys.stderr.write("    - %s\n" % e)
    sys.exit(1)
sys.exit(0)
PY
  then
    echo "FAIL ${fx}-fixture.json" >&2
    fail=1
  else
    echo "PASS ${fx}-fixture.json"
  fi
done

if [[ "$fail" -eq 0 ]]; then
  echo "gain-hunt-analyze-test: all golden fixtures matched expected.json"
  exit 0
fi
echo "gain-hunt-analyze-test: FAILURES (see above)" >&2
exit 1

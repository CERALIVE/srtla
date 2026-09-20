#!/usr/bin/env bash
#
# ab-campaign.sh — run a pre-registered A/B campaign from its scenario document.
#
# The document (tests/compat/scenarios/ab-*.yaml) owns the arms, the groups, the
# run count and the frozen decision rule. This script owns nothing but the
# mechanics: it expands the document into the exact ordered run plan, executes
# it, appends one row per run to rows.json, and hands rows.json to
# tests/compat/lib/ab-verdict.py. It never inspects a metric and never decides a
# winner — that separation is the whole point of pre-registration.
#
# Usage:
#   ab-campaign.sh --scenario <name> --plan         # print the run plan, exit 0
#   ab-campaign.sh --scenario <name> --print-rule   # print the frozen rule
#   ab-campaign.sh --scenario <name> [--out DIR]    # execute the campaign
#
#   --scenario <name>  document stem, e.g. ab-keepalive-cadence
#   --plan             expand and print the plan only. Unprivileged, touches no
#                      network, builds nothing — this is the mode CI and a
#                      reviewer use.
#   --out <dir>        where rows.json / verdict.json land
#                      (default: tests/compat/results/<scenario>/)
#
# EXECUTION IS DELIBERATELY REFUSED HERE (exit 3) until the campaign step wires
# the per-arm build and the per-group impairment for the document it is running.
# Those two things are scenario-specific, need a quiesced bench host with
# CAP_NET_ADMIN, and are gated on preconditions (disk floor, no other campaign,
# a recorded sink image) that this script deliberately does not fake. A refusal
# is loud and exits non-zero; it can never be mistaken for a completed campaign.
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
COMPAT_DIR="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"

die() { printf 'ab-campaign: %s\n' "$*" >&2; exit 2; }

SCENARIO=""
MODE="execute"
OUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario)   SCENARIO="${2:?--scenario needs a value}"; shift 2 ;;
    --plan)       MODE="plan"; shift ;;
    --print-rule) MODE="rule"; shift ;;
    --out)        OUT_DIR="${2:?--out needs a value}"; shift 2 ;;
    -h|--help)    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            die "unknown argument '$1' (try --help)" ;;
  esac
done

[[ -n "$SCENARIO" ]] || die "--scenario is required"
DOC="${COMPAT_DIR}/scenarios/${SCENARIO}.yaml"
[[ -f "$DOC" ]] || die "no such scenario document: ${DOC}"
: "${OUT_DIR:=${COMPAT_DIR}/results/${SCENARIO}}"

command -v python3 >/dev/null 2>&1 || die "python3 is required"

if [[ "$MODE" == "rule" ]]; then
  exec python3 "${COMPAT_DIR}/lib/ab-verdict.py" --print-rule "$DOC"
fi

PLAN="$(python3 - "$DOC" <<'PY'
import sys
import yaml

doc = yaml.safe_load(open(sys.argv[1]))
group_key = doc["group_key"]
print(f"campaign : {doc['name']}")
print(f"instrument: {doc['instrument']}")
print(f"rule kind : {doc['decision']['kind']}")
print(f"runs      : {len(doc['arms'])} arms x {len(doc['groups'])} {group_key}s "
      f"x {doc['runs_per_group']} = "
      f"{len(doc['arms']) * len(doc['groups']) * doc['runs_per_group']} rows")
print("")
for arm in doc["arms"]:
    for group in doc["groups"]:
        for run in range(1, doc["runs_per_group"] + 1):
            settings = {**arm["apply"], **group["apply"]}
            rendered = " ".join(f"{k}={v}" for k, v in settings.items())
            print(f"  arm={arm['id']} {group_key}={group['id']} run={run} :: {rendered}")
PY
)" || die "could not expand ${DOC} (is PyYAML installed? see lib/requirements.txt)"

printf '%s\n' "$PLAN"

if [[ "$MODE" == "plan" ]]; then
  exit 0
fi

cat >&2 <<EOF

ab-campaign: REFUSING to execute '${SCENARIO}'.

The plan above is complete, but the per-arm build and per-group impairment steps
are not wired in this script. Wiring them is the campaign step's job, together
with its preconditions (quiesced host, disk floor, recorded sink image). Results
would land in: ${OUT_DIR}

Use --plan to review the run plan, or --print-rule to read the frozen rule.
EOF
exit 3

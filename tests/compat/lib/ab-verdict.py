#!/usr/bin/env python3
"""Recompute an A/B winner from rows.json under a frozen, pre-registered rule.

The point of this script is that NOBODY gets to judge a campaign. The decision
text lives in the scenario document (`rule:`), the thresholds live beside it in
`decision:`, and this file is the only implementation of that text. A verdict is
therefore a recomputation anyone can repeat from the committed rows.

Entry points
------------
  --selftest              Run every scenario document against three hand-built
                          rows fixtures (clear-A, clear-B, insufficient-runs)
                          and assert the expected winner, plus check that each
                          declared threshold is actually restated in the rule.
  --print-rule <yaml>     Print the document's `rule:` scalar verbatim. Used to
                          prove the committed text still matches its source.
  <rows.json> <yaml>      Apply the rule and print the winner. `--json <path>`
                          additionally writes the full verdict document.

`rule_sha256` is taken over the WHITESPACE-NORMALIZED rule text, so reflowing
the YAML block scalar does not change the identity of the decision procedure,
while any edit to its wording does.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import statistics
import sys
import tempfile
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:
    print(
        "ERROR: PyYAML not installed. Install with: "
        "python3 -m pip install -r tests/compat/lib/requirements.txt",
        file=sys.stderr,
    )
    sys.exit(2)


COMPAT_DIR = Path(__file__).resolve().parent.parent


class RuleError(Exception):
    pass


def normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def rule_sha256(rule: str) -> str:
    return hashlib.sha256(normalize(rule).encode("utf-8")).hexdigest()


def load_document(path: Path) -> dict[str, Any]:
    doc = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(doc, dict) or not isinstance(doc.get("rule"), str):
        raise RuleError(f"{path}: not a scenario document with a `rule:` scalar")
    return doc


def medians(rows: list[dict[str, Any]], doc: dict[str, Any]) -> tuple[dict, list[str]]:
    """Median of each metric per (arm, group), over the valid runs only.

    Returns (table, shortfalls). A shortfall is an (arm, group) that could not
    reach runs_per_group valid runs — the rule's insufficiency trigger."""
    group_key = doc["group_key"]
    required = doc["runs_per_group"]
    metrics = [m for m in doc["metrics"] if m not in ("valid", "censored")]
    group_ids = [g["id"] for g in doc["groups"]]

    table: dict[tuple[str, str], dict[str, float]] = {}
    shortfalls: list[str] = []
    for arm in ("A", "B"):
        for group in group_ids:
            valid = [
                row
                for row in rows
                if row.get("arm") == arm
                and row.get(group_key) == group
                and row.get("valid") is True
            ]
            if len(valid) < required:
                shortfalls.append(f"{arm}/{group}: {len(valid)}/{required} valid runs")
                continue
            table[(arm, group)] = {
                metric: statistics.median(float(row[metric]) for row in valid)
                for metric in metrics
            }
    return table, shortfalls


def decide_d10(table: dict, doc: dict[str, Any]) -> dict[str, Any]:
    decision = doc["decision"]
    band = float(decision["loss_noise_band_pp"])
    guard_ratio = float(decision["goodput_guard_ratio"])
    required = int(decision["groups_required_for_a"])
    primary, guard_metric = decision["primary_metric"], decision["guard_metric"]
    group_ids = [g["id"] for g in doc["groups"]]

    won_by_a = 0
    guard_all = True
    per_group = []
    for group in group_ids:
        a, b = table[("A", group)], table[("B", group)]
        a_wins = a[primary] < b[primary] - band
        guard_ok = a[guard_metric] >= guard_ratio * b[guard_metric]
        won_by_a += int(a_wins)
        guard_all = guard_all and guard_ok
        per_group.append(
            {
                "id": group,
                f"median_{primary}_a": a[primary],
                f"median_{primary}_b": b[primary],
                f"median_{guard_metric}_a": a[guard_metric],
                f"median_{guard_metric}_b": b[guard_metric],
                "a_wins": a_wins,
                "goodput_guard_ok": guard_ok,
            }
        )

    winners = doc["verdict"]["winner_values"]
    elected_a = won_by_a >= required and guard_all
    return {
        "winner": winners["A"] if elected_a else winners["B"],
        "cells_won_by_a": won_by_a,
        "goodput_guard_all_cells": guard_all,
        "reason": (
            f"A won {primary} on {won_by_a}/{len(group_ids)} cells "
            f"with the goodput guard {'holding' if guard_all else 'broken'}"
        ),
        "groups": per_group,
    }


def decide_d21(table: dict, doc: dict[str, Any]) -> dict[str, Any]:
    decision = doc["decision"]
    survival_margin = float(decision["survival_margin"])
    ttr_ratio = float(decision["ttr_ratio"])
    required = int(decision["groups_required_for_b"])
    group_ids = [g["id"] for g in doc["groups"]]

    won_by_b = 0
    per_group = []
    for group in group_ids:
        a, b = table[("A", group)], table[("B", group)]
        survival_win = b["survival"] - a["survival"] >= survival_margin
        ttr_win = b["ttr_ms"] <= ttr_ratio * a["ttr_ms"]
        rereg_guard = b["rereg"] <= a["rereg"]
        b_wins = (survival_win or ttr_win) and rereg_guard
        won_by_b += int(b_wins)
        per_group.append(
            {
                "id": group,
                "median_survival_a": a["survival"],
                "median_survival_b": b["survival"],
                "median_ttr_ms_a": a["ttr_ms"],
                "median_ttr_ms_b": b["ttr_ms"],
                "median_rereg_a": a["rereg"],
                "median_rereg_b": b["rereg"],
                "survival_win": survival_win,
                "ttr_win": ttr_win,
                "rereg_guard_ok": rereg_guard,
                "b_wins": b_wins,
            }
        )

    winners = doc["verdict"]["winner_values"]
    elected_b = won_by_b >= required
    return {
        "winner": winners["B"] if elected_b else winners["A"],
        "scenarios_won_by_b": won_by_b,
        "reason": f"B won {won_by_b}/{len(group_ids)} scenarios",
        "groups": per_group,
    }


DECIDERS = {"d10-loss-goodput": decide_d10, "d21-survival-ttr": decide_d21}


def compute_verdict(rows: list[dict[str, Any]], doc: dict[str, Any]) -> dict[str, Any]:
    kind = doc["decision"]["kind"]
    if kind not in DECIDERS:
        raise RuleError(f"unknown decision kind '{kind}'")

    group_key = doc["group_key"]
    verdict_meta = doc["verdict"]
    base = {
        "scenario": doc["name"],
        "arm_a": verdict_meta["arm_a"],
        "arm_b": verdict_meta["arm_b"],
        "rule_sha256": rule_sha256(doc["rule"]),
        "n": doc["runs_per_group"],
        f"{group_key}s": len(doc["groups"]),
    }

    table, shortfalls = medians(rows, doc)
    if shortfalls:
        return {
            **base,
            "winner": verdict_meta["default_winner"],
            "reason": verdict_meta["insufficient_runs_reason"],
            "shortfalls": shortfalls,
        }
    return {**base, **DECIDERS[kind](table, doc)}


# --------------------------------------------------------------------------- #
# Selftest                                                                     #
# --------------------------------------------------------------------------- #

def _rows(doc: dict[str, Any], values: dict[str, dict[str, float]]) -> list[dict[str, Any]]:
    """Expand per-arm metric values into runs_per_group identical valid rows."""
    group_key = doc["group_key"]
    rows = []
    for arm in ("A", "B"):
        for group in (g["id"] for g in doc["groups"]):
            for run in range(1, doc["runs_per_group"] + 1):
                row = {"arm": arm, group_key: group, "run": run, "valid": True}
                row.update(values[arm])
                if "censored" in doc["metrics"]:
                    row["censored"] = False
                rows.append(row)
    return rows


FIXTURE_VALUES = {
    "d10-loss-goodput": {
        "clear-A": {
            "A": {"loss_pp": 0.100, "goodput_kbps": 4000, "retransmit_ratio": 0.01},
            "B": {"loss_pp": 0.900, "goodput_kbps": 4000, "retransmit_ratio": 0.02},
        },
        "clear-B": {
            "A": {"loss_pp": 0.900, "goodput_kbps": 3000, "retransmit_ratio": 0.03},
            "B": {"loss_pp": 0.100, "goodput_kbps": 4000, "retransmit_ratio": 0.01},
        },
    },
    "d21-survival-ttr": {
        "clear-A": {
            "A": {"survival": 1, "rereg": 0, "ttr_ms": 1000},
            "B": {"survival": 0, "rereg": 3, "ttr_ms": 9000},
        },
        "clear-B": {
            "A": {"survival": 0, "rereg": 2, "ttr_ms": 9000},
            "B": {"survival": 1, "rereg": 0, "ttr_ms": 1000},
        },
    },
}


def _check_rule_restates_thresholds(doc: dict[str, Any]) -> list[str]:
    """A threshold that is not spelled out in the frozen text is not frozen."""
    rule = normalize(doc["rule"])
    problems = []
    for key, value in doc["decision"].items():
        if key == "kind" or not isinstance(value, (int, float)) or isinstance(value, bool):
            continue
        if key.startswith("groups_required_for_"):
            literal = f"{int(value)} of the {len(doc['groups'])}"
            if literal not in rule:
                problems.append(f"decision.{key}={value}: rule never says '{literal}'")
            continue
        candidates = {f"{value}", f"{float(value):.2f}", f"{float(value):.3f}"}
        if not any(candidate in rule for candidate in candidates):
            problems.append(f"decision.{key}={value}: rule restates none of {sorted(candidates)}")
    return problems


def selftest() -> int:
    docs = sorted((COMPAT_DIR / "scenarios").glob("ab-*.yaml"))
    if not docs:
        print("selftest: no scenario documents found", file=sys.stderr)
        return 1

    failures: list[str] = []
    passed = 0
    with tempfile.TemporaryDirectory() as tmp:
        for path in docs:
            doc = load_document(path)
            kind = doc["decision"]["kind"]
            winners = doc["verdict"]["winner_values"]

            for problem in _check_rule_restates_thresholds(doc):
                failures.append(f"{path.name}: {problem}")

            cases = [
                ("clear-A", _rows(doc, FIXTURE_VALUES[kind]["clear-A"]), winners["A"], False),
                ("clear-B", _rows(doc, FIXTURE_VALUES[kind]["clear-B"]), winners["B"], False),
            ]
            starved = _rows(doc, FIXTURE_VALUES[kind]["clear-A"])
            starved[0]["valid"] = False
            cases.append(
                ("insufficient-runs", starved, doc["verdict"]["default_winner"], True)
            )

            for case_name, rows, expected, expect_insufficient in cases:
                fixture = Path(tmp) / f"{path.stem}-{case_name}.rows.json"
                fixture.write_text(json.dumps(rows, indent=2), encoding="utf-8")
                verdict = compute_verdict(
                    json.loads(fixture.read_text(encoding="utf-8")), doc
                )
                label = f"{path.name}/{case_name}"
                insufficient = verdict["reason"] == doc["verdict"]["insufficient_runs_reason"]
                if verdict["winner"] != expected:
                    failures.append(
                        f"{label}: winner {verdict['winner']!r}, expected {expected!r}"
                    )
                elif insufficient != expect_insufficient:
                    failures.append(
                        f"{label}: insufficiency={insufficient}, expected {expect_insufficient}"
                    )
                else:
                    passed += 1
                    print(f"  PASS {label}: winner={verdict['winner']} reason={verdict['reason']}")

    if failures:
        print(f"\nSELFTEST FAILED ({len(failures)})", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(f"\nSELFTEST PASSED: {passed} fixtures across {len(docs)} rules")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, add_help=True)
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--print-rule", metavar="YAML")
    parser.add_argument("rows", nargs="?", metavar="ROWS_JSON")
    parser.add_argument("document", nargs="?", metavar="SCENARIO_YAML")
    parser.add_argument("--json", metavar="PATH", help="also write the full verdict document")
    args = parser.parse_args()

    if args.selftest:
        return selftest()

    if args.print_rule:
        sys.stdout.write(load_document(Path(args.print_rule))["rule"])
        return 0

    if not args.rows or not args.document:
        parser.error("need <rows.json> <scenario.yaml>, or --selftest, or --print-rule")

    doc = load_document(Path(args.document))
    rows = json.loads(Path(args.rows).read_text(encoding="utf-8"))
    verdict = compute_verdict(rows, doc)
    print(verdict["winner"])
    if args.json:
        Path(args.json).write_text(json.dumps(verdict, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except RuleError as exc:
        print(f"ab-verdict: {exc}", file=sys.stderr)
        sys.exit(2)

#!/usr/bin/env python3
"""Schema check for the compat registry and the pre-registered A/B documents.

Two independent surfaces share one entry point because both are consumed by the
same harness and both must be well-formed before any campaign is launched:

  1. matrix.yaml           the sender/receiver/pair registry CI fans out from.
  2. scenarios/ab-*.yaml   the frozen A/B decision documents whose `rule:` text
                           is the only thing allowed to pick a winner.

Exit 0 = both valid. Run it directly, or via `run-matrix.sh --validate-only`.
"""

from __future__ import annotations

import re
import sys
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
    sys.exit(1)


SCENARIO_SCHEMA_VERSION = 1
GROUP_KEYS = ("cell", "scenario")

DECISION_THRESHOLDS: dict[str, tuple[str, ...]] = {
    "d10-loss-goodput": (
        "loss_noise_band_pp",
        "goodput_guard_ratio",
        "groups_required_for_a",
    ),
    "d21-survival-ttr": (
        "survival_margin",
        "ttr_ratio",
        "groups_required_for_b",
    ),
}


def validate_pin(pin: Any, context: str) -> str | None:
    if not isinstance(pin, str):
        return f"{context}: pin is not a string (got {type(pin).__name__})"
    if not re.fullmatch(r"[0-9a-f]{40}", pin):
        return f"{context}: pin must be a 40-char lowercase hex sha (got '{pin}')"
    return None


def validate_impl(entry: Any, index: int, section: str, role: str) -> tuple[str | None, list[str]]:
    """Validate one senders[]/receivers[] entry. Returns (name, errors)."""
    errors: list[str] = []
    context = f"{section}[{index}]"
    if not isinstance(entry, dict):
        return None, [f"{context}: entry must be a dict"]

    name = entry.get("name")
    if not name:
        return None, [f"{context}: missing 'name' field"]
    context = f"{context} ({name})"

    for field in ("repo", "role", "tier"):
        if field not in entry:
            errors.append(f"{context}: missing '{field}' field")

    has_pin, has_ref = "pin" in entry, "ref" in entry
    if has_pin == has_ref:
        errors.append(
            f"{context}: needs exactly one of 'pin' (immutable 40-hex sha) "
            "or 'ref' (a moving branch/tag we own)"
        )
    elif has_pin:
        message = validate_pin(entry["pin"], context)
        if message:
            errors.append(message)
    elif not isinstance(entry.get("ref"), str) or not entry["ref"].strip():
        errors.append(f"{context}: 'ref' must be a non-empty string")

    if entry.get("role") not in (None, role):
        errors.append(f"{context}: role must be '{role}', got '{entry.get('role')}'")
    if entry.get("tier") not in (None, "blocking", "informational"):
        errors.append(
            f"{context}: tier must be 'blocking' or 'informational', got '{entry.get('tier')}'"
        )
    return name, errors


def validate_matrix(matrix_path: Path) -> tuple[bool, list[str]]:
    errors: list[str] = []
    try:
        matrix = yaml.safe_load(matrix_path.read_text())
    except Exception as exc:
        return False, [f"failed to load {matrix_path}: {exc}"]
    if not isinstance(matrix, dict):
        return False, [f"{matrix_path}: root must be a mapping"]

    srt = matrix.get("srt")
    if not isinstance(srt, dict):
        errors.append("srt: missing the libsrt-under-test declaration")
    else:
        if not srt.get("repo"):
            errors.append("srt: missing 'repo'")
        if ("pin" in srt) == ("ref" in srt):
            errors.append("srt: needs exactly one of 'pin' or 'ref'")

    names: dict[str, set[str]] = {}
    for section, role in (("senders", "sender"), ("receivers", "receiver")):
        entries = matrix.get(section, [])
        names[section] = set()
        if not isinstance(entries, list):
            errors.append(f"{section} must be a list")
            continue
        for index, entry in enumerate(entries):
            name, entry_errors = validate_impl(entry, index, section, role)
            errors.extend(entry_errors)
            if name:
                names[section].add(name)

    tier_counts = {"blocking": 0, "informational": 0}
    pairs = matrix.get("pairs", [])
    if not isinstance(pairs, list):
        errors.append("pairs must be a list")
        pairs = []
    for index, pair in enumerate(pairs):
        context = f"pairs[{index}]"
        if not isinstance(pair, dict):
            errors.append(f"{context}: entry must be a dict")
            continue
        for field, pool in (("sender", "senders"), ("receiver", "receivers")):
            value = pair.get(field)
            if not value:
                errors.append(f"{context}: missing '{field}' field")
            elif value != "ours" and value not in names.get(pool, set()):
                errors.append(f"{context}: {field} '{value}' not found in {pool} list")
        tier = pair.get("tier")
        if tier in tier_counts:
            tier_counts[tier] += 1
        else:
            errors.append(f"{context}: tier must be 'blocking' or 'informational', got '{tier}'")

    invariants = matrix.get("invariants")
    if not isinstance(invariants, dict):
        errors.append("invariants: missing declared pair cardinality")
    else:
        for tier, actual in tier_counts.items():
            declared = invariants.get(f"{tier}_pairs")
            if declared != actual:
                errors.append(
                    f"invariants.{tier}_pairs declares {declared!r} "
                    f"but the pair table holds {actual}"
                )

    for index, entry in enumerate(matrix.get("excluded", []) or []):
        context = f"excluded[{index}]"
        if not isinstance(entry, dict):
            errors.append(f"{context}: entry must be a dict")
            continue
        for field in ("name", "repo", "reason"):
            if field not in entry:
                errors.append(f"{context}: missing '{field}' field")

    if not errors:
        print(
            f"  matrix.yaml: senders={len(matrix.get('senders') or [])} "
            f"receivers={len(matrix.get('receivers') or [])} "
            f"pairs={len(pairs)} "
            f"(blocking={tier_counts['blocking']}, "
            f"informational={tier_counts['informational']})"
        )
    return not errors, errors


def validate_scenario(path: Path) -> tuple[bool, list[str]]:
    errors: list[str] = []
    try:
        doc = yaml.safe_load(path.read_text())
    except Exception as exc:
        return False, [f"{path.name}: failed to load: {exc}"]
    if not isinstance(doc, dict):
        return False, [f"{path.name}: root must be a mapping"]

    def err(message: str) -> None:
        errors.append(f"{path.name}: {message}")

    if doc.get("schema_version") != SCENARIO_SCHEMA_VERSION:
        err(f"schema_version must be {SCENARIO_SCHEMA_VERSION}, got {doc.get('schema_version')!r}")
    if doc.get("name") != path.stem:
        err(f"name '{doc.get('name')}' does not match the file stem '{path.stem}'")
    for field in ("question", "instrument"):
        if not isinstance(doc.get(field), str) or not doc[field].strip():
            err(f"'{field}' must be a non-empty string")

    group_key = doc.get("group_key")
    if group_key not in GROUP_KEYS:
        err(f"group_key must be one of {GROUP_KEYS}, got {group_key!r}")

    runs = doc.get("runs_per_group")
    if not isinstance(runs, int) or runs < 1:
        err("runs_per_group must be a positive integer")

    arms = doc.get("arms")
    if not isinstance(arms, list) or len(arms) != 2:
        err("arms must be a list of exactly two entries")
    else:
        if [arm.get("id") if isinstance(arm, dict) else None for arm in arms] != ["A", "B"]:
            err("arms must be declared in order with ids 'A' and 'B'")
        for arm in arms:
            if not isinstance(arm, dict):
                err("each arm must be a mapping")
                continue
            if not isinstance(arm.get("label"), str) or not arm["label"].strip():
                err(f"arm {arm.get('id')!r} needs a non-empty label")
            if not isinstance(arm.get("apply"), dict) or not arm["apply"]:
                err(f"arm {arm.get('id')!r} needs a non-empty 'apply' mapping")

    groups = doc.get("groups")
    if not isinstance(groups, list) or not groups:
        err("groups must be a non-empty list")
    else:
        ids = [group.get("id") if isinstance(group, dict) else None for group in groups]
        if any(not isinstance(value, str) or not value for value in ids):
            err("every group needs a string 'id'")
        elif len(set(ids)) != len(ids):
            err("group ids must be unique")

    metrics = doc.get("metrics")
    if not isinstance(metrics, list) or not metrics:
        err("metrics must be a non-empty list")
    elif "valid" not in metrics:
        err("metrics must include 'valid' (the per-run validity flag the rule keys on)")
    else:
        units = doc.get("units")
        if not isinstance(units, dict):
            err("units must be a mapping")
        else:
            missing = [m for m in metrics if m != "valid" and m not in units]
            if missing:
                err(f"units omits {', '.join(missing)}")

    decision = doc.get("decision")
    if not isinstance(decision, dict):
        err("decision must be a mapping")
    else:
        kind = decision.get("kind")
        if kind not in DECISION_THRESHOLDS:
            err(f"decision.kind must be one of {tuple(DECISION_THRESHOLDS)}, got {kind!r}")
        else:
            for key in DECISION_THRESHOLDS[kind]:
                if not isinstance(decision.get(key), (int, float)):
                    err(f"decision.{key} must be numeric for kind '{kind}'")

    verdict = doc.get("verdict")
    if not isinstance(verdict, dict):
        err("verdict must be a mapping")
    else:
        for field in ("arm_a", "arm_b", "default_winner", "insufficient_runs_reason"):
            if field not in verdict:
                err(f"verdict.{field} is missing")
        winners = verdict.get("winner_values")
        if not isinstance(winners, dict) or set(winners) != {"A", "B"}:
            err("verdict.winner_values must map exactly 'A' and 'B'")
        elif verdict.get("default_winner") not in winners.values():
            err("verdict.default_winner must be one of verdict.winner_values")

    rule = doc.get("rule")
    if not isinstance(rule, str) or not rule.strip():
        err("rule must be a non-empty string (the frozen decision text)")

    if not errors:
        print(f"  {path.name}: {len(doc['groups'])} groups x 2 arms x {runs} runs, kind={doc['decision']['kind']}")
    return not errors, errors


def main() -> int:
    compat_dir = Path(__file__).resolve().parent
    matrix_path = compat_dir / "matrix.yaml"
    if not matrix_path.exists():
        print(f"ERROR: {matrix_path} not found", file=sys.stderr)
        return 1

    all_errors: list[str] = []
    ok, errors = validate_matrix(matrix_path)
    all_errors.extend(errors)

    scenario_docs = sorted((compat_dir / "scenarios").glob("ab-*.yaml"))
    if not scenario_docs:
        all_errors.append("scenarios: no pre-registered A/B document (ab-*.yaml) found")
    for path in scenario_docs:
        _, errors = validate_scenario(path)
        all_errors.extend(errors)

    if all_errors:
        print("VALIDATION FAILED", file=sys.stderr)
        print(f"\nErrors ({len(all_errors)}):", file=sys.stderr)
        for error in all_errors:
            print(f"  - {error}", file=sys.stderr)
        return 1

    print("VALIDATION PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())

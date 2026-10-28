"""Shared, dependency-free boundary for fixture-only benchmark commands."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path
from typing import TypeAlias

Json: TypeAlias = None | bool | int | float | str | list["Json"] | dict[str, "Json"]
JsonMap: TypeAlias = dict[str, Json]


def mapping(value: Json) -> JsonMap:
    if not isinstance(value, dict):
        raise ValueError("expected a JSON object")
    return value


def rows(value: Json) -> list[Json]:
    if not isinstance(value, list) or not value:
        raise ValueError("expected a nonempty JSON array")
    return value


def text(value: Json) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError("expected a nonempty string")
    return value


def number(value: Json, *, positive: bool = False) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError("expected a numeric metric")
    if not math.isfinite(value) or value < 0 or (positive and value == 0):
        raise ValueError("metrics must be finite and nonnegative (positive for divisors)")
    return float(value)


def integer(value: Json, *, positive: bool = False) -> int:
    metric = number(value, positive=positive)
    if not metric.is_integer():
        raise ValueError("expected an integer metric")
    return int(metric)


def series(value: Json, *, counter: bool = False) -> list[float]:
    values = [number(item) for item in rows(value)]
    if len(values) < 3:
        raise ValueError("at least three samples are required")
    if counter and any(b < a for a, b in zip(values, values[1:])):
        raise ValueError("counter reset invalidates the measurement")
    return values


def fixture_document(value: Json) -> JsonMap:
    document = mapping(value)
    if integer(document.get("schema_version")) != 1 or document.get("source") != "fixture":
        raise ValueError("only schema_version 1, source fixture is accepted")
    return document


def run(
    name: str,
    evaluate: Callable[[Json], JsonMap],
    rule: str,
    test_class: str,
) -> int:
    parser = argparse.ArgumentParser(description=f"{name}: fixture evaluation; live runs are owner-gated")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--selftest", action="store_true")
    mode.add_argument("--fixture", type=Path)
    mode.add_argument("--live", action="store_true")
    if name == "relay-capacity-probe":
        mode.add_argument("--real-host", action="store_true")
    parser.add_argument("--output", type=Path, help="new verdict.json; existing files are never replaced")
    args = parser.parse_args()
    if args.output is not None and args.fixture is None:
        parser.error("--output requires --fixture")
    if args.selftest:
        return subprocess.run(
            [sys.executable, str(Path(__file__).with_name("test_benchmark_harnesses.py")), test_class, "CliTests"],
            check=False, timeout=60,
        ).returncode
    if args.fixture is None:
        print(json.dumps({
            "scenario": name, "status": "SKIP", "qualified": False,
            "reason": "live capacity/provider/netns legs require owner-gated todo 43; no live run performed",
        }))
        return 77
    if args.output is None:
        parser.error("--fixture requires --output")
    try:
        raw = args.fixture.read_bytes()
        document: Json = json.loads(raw)
        result = evaluate(document)
        result["rule_sha256"] = hashlib.sha256(rule.encode()).hexdigest()
        result["input_sha256"] = hashlib.sha256(raw).hexdigest()
        rendered = json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + "\n"
        with args.output.open("x", encoding="utf-8") as destination:
            destination.write(rendered)
        print(rendered, end="")
        return 1 if result["winner"] == "insufficient" else 0
    except (OSError, ValueError, KeyError) as error:
        print(f"{name}: {error}", file=sys.stderr)
        return 2

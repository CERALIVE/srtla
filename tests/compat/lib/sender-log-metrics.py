#!/usr/bin/env python3
"""Extract the D21 per-run metrics from an srtla_send (Rust) tracing log.

The ab-keepalive-cadence rule is SENDER-centric on purpose: the question is
whether a receiver-side cadence change helps the sender keep and recover a
bonded uplink, so every metric is read from what the sender itself observed.

Emitted per run (one JSON object):
  survival  1 iff the uplink is ACTIVE in the sender's last status report AND no
            REG1 was sent for it after the impairment started, else 0.
  rereg     count of REG3 acceptances for the uplink after the impairment start.
  ttr_ms    first DATA forwarded on the uplink after the impairment ENDED, minus
            the impairment end. No DATA before the run ends => the censored
            maximum (run end - impairment end) with censored=true.
  censored  true when ttr_ms was censored at that maximum.
  valid     false when the capture covers < 90% of the declared run duration, or
            a required marker set is missing entirely.

LOG-MARKER CONTRACT
-------------------
The regexes in MARKERS are the only coupling to the sender build. They are
matched against srtla_send's `tracing` output at DEBUG level (`--verbose` or
RUST_LOG=debug) — REG3 acceptance and the per-selection lines are debug-level,
so an INFO-only capture cannot produce `rereg` or `ttr_ms` and is reported
invalid rather than silently zero. Re-validate this table against the sender
under test as a campaign precondition; a marker that stopped matching shows up
as an invalid run, never as a favourable number.

`--selftest` runs the committed fixture logs and asserts the expected rows.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

COMPAT_DIR = Path(__file__).resolve().parent.parent
FIXTURE_DIR = COMPAT_DIR / "fixtures" / "sender-log"

MIN_CAPTURE_COVERAGE = 0.90

TIMESTAMP = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+)Z?")

MARKERS = {
    "reg1": re.compile(r"REG1 (?:→|->) uplink #(?P<idx>\d+)"),
    "reg3": re.compile(r"REG3 from uplink #(?P<idx>\d+)"),
    "selected": re.compile(
        r"(?:Initial connection selected: |Connection switch: .* (?:→|->) )(?P<label>\S+)"
    ),
    "status": re.compile(r"\[(?P<idx>\d+)\] (?P<state>ACTIVE|TIMED_OUT) (?P<label>\S+)"),
}


def parse_timestamp_ms(line: str) -> float | None:
    match = TIMESTAMP.match(line)
    if not match:
        return None
    return datetime.fromisoformat(match.group(1)).timestamp() * 1000.0


def extract(
    log_text: str,
    uplink_index: int,
    uplink_label: str,
    impairment_start_ms: int,
    impairment_end_ms: int,
    duration_ms: int,
) -> dict[str, Any]:
    first_ms: float | None = None
    last_ms: float = 0.0

    reg1_after_impairment = 0
    rereg = 0
    first_data_ms: float | None = None
    last_status_state: str | None = None
    saw_debug_markers = False

    for line in log_text.splitlines():
        stamp = parse_timestamp_ms(line)
        if stamp is None:
            continue
        if first_ms is None:
            first_ms = stamp
        offset = stamp - first_ms
        last_ms = offset

        match = MARKERS["reg1"].search(line)
        if match and int(match.group("idx")) == uplink_index and offset >= impairment_start_ms:
            reg1_after_impairment += 1

        match = MARKERS["reg3"].search(line)
        if match:
            saw_debug_markers = True
            if int(match.group("idx")) == uplink_index and offset >= impairment_start_ms:
                rereg += 1

        match = MARKERS["status"].search(line)
        if match and match.group("label") == uplink_label:
            last_status_state = match.group("state")

        match = MARKERS["selected"].search(line)
        if match:
            saw_debug_markers = True
            if (
                first_data_ms is None
                and match.group("label") == uplink_label
                and offset >= impairment_end_ms
            ):
                first_data_ms = offset

    coverage = (last_ms / duration_ms) if (first_ms is not None and duration_ms) else 0.0
    censored = first_data_ms is None
    ttr_ms = int(
        duration_ms - impairment_end_ms if censored else first_data_ms - impairment_end_ms
    )
    survival = int(last_status_state == "ACTIVE" and reg1_after_impairment == 0)

    valid = (
        first_ms is not None
        and saw_debug_markers
        and last_status_state is not None
        and coverage >= MIN_CAPTURE_COVERAGE
    )

    return {
        "survival": survival,
        "rereg": rereg,
        "ttr_ms": ttr_ms,
        "censored": censored,
        "valid": valid,
        "capture_coverage": round(coverage, 4),
    }


FIXTURE_EXPECTATIONS = {
    "s1-arm-b-recovered.log": {
        "survival": 1,
        "rereg": 0,
        "censored": False,
        "valid": True,
    },
    "s1-arm-a-lost.log": {
        "survival": 0,
        "rereg": 1,
        "censored": True,
        "valid": True,
    },
    "s1-truncated-capture.log": {
        "valid": False,
    },
}


def selftest() -> int:
    failures = []
    for name, expected in FIXTURE_EXPECTATIONS.items():
        row = extract(
            (FIXTURE_DIR / name).read_text(encoding="utf-8"),
            uplink_index=1,
            uplink_label="192.0.2.11",
            impairment_start_ms=20_000,
            impairment_end_ms=30_000,
            duration_ms=60_000,
        )
        mismatched = {k: (row[k], v) for k, v in expected.items() if row[k] != v}
        if mismatched:
            failures.append(f"{name}: {mismatched}")
        else:
            print(f"  PASS {name}: {json.dumps(row)}")

    if failures:
        print(f"\nSELFTEST FAILED ({len(failures)})", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(f"\nSELFTEST PASSED: {len(FIXTURE_EXPECTATIONS)} fixtures")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="D21 sender-log metric extraction")
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--log", type=Path)
    parser.add_argument("--uplink-index", type=int, default=1)
    parser.add_argument("--uplink-label", default="")
    parser.add_argument("--impairment-start-ms", type=int, default=20_000)
    parser.add_argument("--impairment-end-ms", type=int, default=30_000)
    parser.add_argument("--duration-ms", type=int, default=60_000)
    parser.add_argument("--arm")
    parser.add_argument("--scenario")
    parser.add_argument("--run", type=int)
    args = parser.parse_args()

    if args.selftest:
        return selftest()
    if not args.log or not args.uplink_label:
        parser.error("need --log and --uplink-label (or --selftest)")

    row = extract(
        args.log.read_text(encoding="utf-8"),
        args.uplink_index,
        args.uplink_label,
        args.impairment_start_ms,
        args.impairment_end_ms,
        args.duration_ms,
    )
    for key, value in (("arm", args.arm), ("scenario", args.scenario), ("run", args.run)):
        if value is not None:
            row = {key: value, **row}
    print(json.dumps(row))
    return 0


if __name__ == "__main__":
    sys.exit(main())

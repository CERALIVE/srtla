#!/usr/bin/env python3
"""Per-run D10 row extraction from a reorder-stress ``result.json``.

The frozen rule for ``ab-periodic-nak`` records four metrics per run. This file
is the single place that turns the instrument's raw receiver counters into them,
so the definition cannot drift between runs:

    loss_pp           viewer-observed loss, percentage points, 3 decimals.
                      The SRT receiver's ``pktRcvDropTotal`` is precisely the set
                      of packets NOT delivered to the application (never-arrived,
                      too-late, or undecryptable). As a fraction of the packets
                      the application needed (delivered unique + dropped):
                          loss_pp = 100 * drop / (unique + drop)
    goodput_kbps      delivered rate in kilobits per second. The instrument's
                      ``metrics.goodput_bps`` is bytes/second (its own summary
                      labels the quantity "delivered B/s"), so the x8 conversion
                      to bits is applied here.
    retransmit_ratio  receiver-observed repeat ratio,
                      (pktRecvTotal - pktRecvUniqueTotal) / pktRecvTotal.
                      libsrt 1.5.6 (the headers srt-sink compiles against) has no
                      ``pktRcvRetransTotal``, so this cumulative stand-in is used.
    valid             false on a harness error (exit not 0/1), a missing metric,
                      or a sink capture shorter than 90 % of the declared
                      scenario duration.

Usage:
    ab-row-metrics.py --result R.json --exit-code N --expected-ms MS \\
        --arm A --cell loss0.5-reorder10 --run 1
    ab-row-metrics.py --selftest
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

MIN_CAPTURE_COVERAGE = 0.90


def extract(
    result: dict | None,
    exit_code: int,
    expected_ms: int,
    arm: str,
    cell: str,
    run: int,
) -> dict:
    row: dict = {"arm": arm, "cell": cell, "run": run,
                 "loss_pp": None, "goodput_kbps": None,
                 "retransmit_ratio": None, "valid": False}
    if result is None or exit_code not in (0, 1):
        return row

    # reorder-stress result.json: duration under `sink` (integer seconds); the
    # receiver counters and goodput under `metrics`.
    sink = result.get("sink") if isinstance(result.get("sink"), dict) else {}
    metrics = result.get("metrics") if isinstance(result.get("metrics"), dict) else {}
    duration_s = sink.get("duration_s")
    goodput_bytes_s = metrics.get("goodput_bps")
    drop = metrics.get("pkt_rcv_drop")
    unique = metrics.get("pkt_rcv_unique")
    total = metrics.get("pkt_rcv_total")

    if not isinstance(duration_s, (int, float)) or expected_ms <= 0:
        return row
    if duration_s < MIN_CAPTURE_COVERAGE * (expected_ms / 1000.0):
        return row
    if drop is None or unique is None or (drop + unique) <= 0:
        return row
    if not isinstance(goodput_bytes_s, (int, float)):
        return row

    row["loss_pp"] = round(100.0 * drop / (unique + drop), 3)
    row["goodput_kbps"] = int(round(float(goodput_bytes_s) * 8 / 1000.0))
    repeats = 0
    if total and total > 0:
        repeats = max(0, total - unique)
        row["retransmit_ratio"] = round(repeats / total, 4)
    else:
        row["retransmit_ratio"] = 0.0
    row["valid"] = True
    return row


def _fixture(**overrides) -> dict:
    base = {
        "sink": {"duration_s": 35},
        "metrics": {
            "goodput_bps": 87_500,
            "pkt_rcv_drop": 120,
            "pkt_rcv_unique": 23_880,
            "pkt_rcv_total": 24_600,
        },
    }
    base.update(overrides)
    return base


def selftest() -> int:
    cases = [
        ("valid", _fixture(), 0, 33_000, True),
        ("fail-but-ran", _fixture(), 1, 33_000, True),
        ("harness-error", _fixture(), 2, 33_000, False),
        ("short-capture", _fixture(sink={"duration_s": 20}), 0, 33_000, False),
        ("no-packets", _fixture(metrics={"goodput_bps": 87_500,
                                         "pkt_rcv_drop": 0, "pkt_rcv_unique": 0,
                                         "pkt_rcv_total": 0}), 0, 33_000, False),
        ("missing-goodput", _fixture(metrics={"pkt_rcv_drop": 1, "pkt_rcv_unique": 1,
                                              "pkt_rcv_total": 1}), 0, 33_000, False),
        ("no-result", None, 0, 33_000, False),
    ]
    failures = []
    for name, result, code, expected_ms, want_valid in cases:
        row = extract(result, code, expected_ms, "A", "cell", 1)
        problem = None
        if row["valid"] is not want_valid:
            problem = f"valid={row['valid']} want {want_valid}"
        elif want_valid:
            # 120 / (23880+120) * 100 = 0.500 ; 87500 B/s * 8 / 1000 = 700 kbps
            if row["loss_pp"] != 0.5 or row["goodput_kbps"] != 700:
                problem = f"metrics {row}"
            elif row["retransmit_ratio"] != round(720 / 24600, 4):
                problem = f"retransmit_ratio={row['retransmit_ratio']}"
        if problem:
            failures.append(f"{name}: {problem}")
        print(f"  {'FAIL' if problem else 'PASS'} {name}: {json.dumps(row)}")
    if failures:
        print(f"\nSELFTEST FAILED ({len(failures)})", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    print(f"\nSELFTEST PASSED: {len(cases)} fixtures")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="D10 per-run row extraction")
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--result", type=Path)
    parser.add_argument("--exit-code", type=int, default=0)
    parser.add_argument("--expected-ms", type=int, default=0)
    parser.add_argument("--arm", default="")
    parser.add_argument("--cell", default="")
    parser.add_argument("--run", type=int, default=0)
    args = parser.parse_args()

    if args.selftest:
        return selftest()
    if args.result is None:
        parser.error("--result is required (or --selftest)")

    result = None
    try:
        result = json.loads(args.result.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        result = None
    print(json.dumps(extract(result, args.exit_code, args.expected_ms,
                             args.arm, args.cell, args.run)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""H1 fixture evaluator. No load is generated and no provider is qualified."""

from __future__ import annotations

import math
from fractions import Fraction
from itertools import product
from typing import Final

from benchmark_fixture_io import (
    Json, JsonMap, fixture_document, integer, mapping, number, rows, run, series, text,
)

RULE: Final = (
    "H1 v1: stock receiver, unchanged main sender; bonds 1..200; "
    "all 6/10/20 Mbps x 1/4/16 links cells at a bond count must pass; "
    "duration >=1800s, every core CPU <70%, NIC Mbps and pps in/out <=60% sustainable; "
    "no auth failure, eviction, disconnect or UDP receive-error delta; "
    "goodput within 5% of baseline; monotonic RSS growth no worse than stock over same window; "
    "softCapBonds=floor(min(bonds,0.6*min(NIC in,out)/6,0.6*min(pps in,out)/pps per bond at 6Mbps)); "
    "maxAssignedRelays=2*softCapBonds; receiver cpu_bound requires core >=85%, "
    "climbing interval recvmmsg fill, NIC <=60% and SLS CPU <70%; "
    "preview cap=max transcodes with CPU <70%, >=9.5fps for >=1800s; "
    "fixtures never qualify a provider."
)
MATRIX: Final = set(product((6, 10, 20), (1, 4, 16)))


def capacity(bonds: int, nic_mbps: float, pps: float, per_bond_pps: float) -> tuple[int, int]:
    for value in (bonds, nic_mbps, pps, per_bond_pps):
        number(value, positive=True)
    cap = math.floor(min(
        Fraction(bonds),
        Fraction(3, 5) * Fraction(str(nic_mbps)) / 6,
        Fraction(3, 5) * Fraction(str(pps)) / Fraction(str(per_bond_pps)),
    ))
    return cap, 2 * cap


def evaluate(value: Json) -> JsonMap:
    document = fixture_document(value)
    if document.get("sender_ref") != "main" or document.get("receiver") != "stock":
        raise ValueError("H1 requires unchanged main sender and stock receiver")
    provider_class = text(document["provider_class"])
    nic = mapping(document["sustainable_nic_mbps"])
    pps = mapping(document["sustainable_pps"])
    nic_in, nic_out = (number(nic[key], positive=True) for key in ("in", "out"))
    pps_in, pps_out = (number(pps[key], positive=True) for key in ("in", "out"))
    per_bond_pps = number(document["per_bond_pps_6mbps"], positive=True)
    seen: set[tuple[int, int, int]] = set()
    passed: dict[int, set[tuple[int, int]]] = {}
    cell_results: list[Json] = []
    cpu_bound = False
    for raw in rows(document["cells"]):
        cell = mapping(raw)
        bonds = integer(cell["bonds"], positive=True)
        bitrate = integer(cell["bitrate_mbps"])
        links = integer(cell["links"])
        key = (bonds, bitrate, links)
        if bonds > 200 or (bitrate, links) not in MATRIX or key in seen:
            raise ValueError("cell must be unique, bonds <=200, bitrate 6/10/20, links 1/4/16")
        seen.add(key)
        duration = number(cell["duration_s"], positive=True)
        cores = [number(core) for core in rows(cell["per_core_cpu_pct"])]
        receiver_core = integer(cell["receiver_core"])
        if max(cores) > 100 or receiver_core >= len(cores):
            raise ValueError("invalid per-core CPU percentage or receiver_core index")
        sls_cpu = number(cell["sls_cpu_pct"])
        if sls_cpu > 100:
            raise ValueError("SLS CPU must be a percentage")
        nic_load = max(number(cell["nic_in_mbps"]) / nic_in, number(cell["nic_out_mbps"]) / nic_out)
        pps_load = max(number(cell["pps_in"]) / pps_in, number(cell["pps_out"]) / pps_out)
        packets = series(cell["packets_received"], counter=True)
        batches = series(cell["recv_batches"], counter=True)
        errors = series(cell["udp_receive_errors"], counter=True)
        rss = series(cell["rss_bytes"])
        stock_rss = series(cell["stock_rss_bytes"])
        fds = series(cell["fd_count"])
        if len({len(s) for s in (packets, batches, errors, rss, stock_rss, fds)}) != 1:
            raise ValueError("sample arrays must cover the same evenly spaced window")
        batch_deltas = [b - a for a, b in zip(batches, batches[1:])]
        if min(batch_deltas) <= 0:
            raise ValueError("receive batch deltas must be positive")
        fill = [(b - a) / count for a, b, count in zip(packets, packets[1:], batch_deltas)]
        if min(fill) < 1:
            raise ValueError("recvmmsg batches must contain packets")
        climbing = all(b > a for a, b in zip(fill, fill[1:]))
        bound = duration >= 1800 and cores[receiver_core] >= 85 and climbing and nic_load <= 0.6 and sls_cpu < 70
        cpu_bound = cpu_bound or bound
        monotonic_growth = rss[-1] > rss[0] and all(b >= a for a, b in zip(rss, rss[1:]))
        rss_ok = not monotonic_growth or rss[-1] - rss[0] <= stock_rss[-1] - stock_rss[0]
        goodput = number(cell["delivered_goodput_mbps"])
        baseline = number(cell["baseline_goodput_mbps"], positive=True)
        checks = {
            "window": duration >= 1800,
            "cpu": max(cores) < 70,
            "nic": nic_load <= 0.6,
            "pps": pps_load <= 0.6,
            "udp": errors[-1] == errors[0],
            "rss": rss_ok,
            "goodput": abs(goodput - baseline) <= baseline * 0.05,
            "auth": integer(cell["auth_failures"]) == 0,
            "evictions": integer(cell["evictions"]) == 0,
            "disconnects": integer(cell["disconnects"]) == 0,
        }
        ok = all(checks.values())
        if ok:
            passed.setdefault(bonds, set()).add((bitrate, links))
        cell_results.append({
            "bonds": bonds, "bitrate_mbps": bitrate, "links": links,
            "pass": ok, "checks": checks, "cpu_bound": bound, "recvmmsg_fill": fill,
            "rss_slope_bytes_per_second": (rss[-1] - rss[0]) / duration,
            "fd_peak": max(fds), "metrics": cell,
        })
    bond_count = max((bonds for bonds, matrix in passed.items() if matrix == MATRIX), default=0)
    soft_cap, max_assigned = (0, 0)
    if bond_count:
        soft_cap, max_assigned = capacity(bond_count, min(nic_in, nic_out), min(pps_in, pps_out), per_bond_pps)
    preview_cap = 0
    trials = rows(document["preview_trials"])
    preview_counts: set[int] = set()
    for raw in trials:
        trial = mapping(raw)
        count = integer(trial["transcodes"], positive=True)
        if count in preview_counts:
            raise ValueError("duplicate preview concurrency")
        preview_counts.add(count)
        cpu = number(trial["cpu_pct"])
        if cpu > 100:
            raise ValueError("preview CPU must be a percentage")
        if number(trial["duration_s"]) >= 1800 and cpu < 70 and number(trial["minimum_fps"]) >= 9.5:
            preview_cap = max(preview_cap, count)
    return {
        "scenario": "H1", "source": "fixture", "qualified": False,
        "winner": "fixture_capacity" if soft_cap else "insufficient",
        "provider_class": provider_class, "bond_count_result": bond_count,
        "softCapBonds": soft_cap, "maxAssignedRelays": max_assigned,
        "cpu_bound": cpu_bound, "preview_transcode_max": preview_cap,
        "preview_trials": trials, "cells": cell_results,
        "sustainable_nic_mbps": nic, "sustainable_pps": pps,
        "per_bond_pps_6mbps": per_bond_pps,
    }


if __name__ == "__main__":
    raise SystemExit(run("relay-capacity-probe", evaluate, RULE, "CapacityTests"))

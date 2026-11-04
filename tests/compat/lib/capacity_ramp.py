"""Explicit H1 v3 ceiling search and confirmation; v1/v2 remain frozen."""

from __future__ import annotations

import hashlib
from collections.abc import Callable
from typing import Final

from benchmark_fixture_io import Json, JsonMap, fixture_document, integer, mapping, number, rows

RULE_V3: Final = (
    "H1 v3: explicit ramp mode; unchanged main sender and stock receiver; "
    "default profiles 6Mbps/2links,6Mbps/4links,10Mbps/4links; "
    "start 5 streams, increment 5, max 200, step 300s, sample every 10s; "
    "break if delivered/offered <0.98, SRT drop/loss delta exceeds recorded limits "
    "(default 0 packets each), any core >=95% for >half its interval samples, "
    "UDP RcvbufErrors/SndbufErrors grows, publisher start fails or disconnects; "
    "offered must be within 5% of requested load; "
    "ceiling=last passing step, >=max is only a measured lower bound; "
    "confirm floor(4*ceiling/5) for >=1800s after >=600s warmup; "
    "RSS uses v2 positive nondecreasing growth no worse than a separate stock arm "
    "over the same retained window; failed confirmation steps down one increment, "
    "at most two attempts total; failed stock arm fails that attempt; "
    "softCapBonds=min confirmed counts, maxAssignedRelays=2*softCapBonds; "
    "sustainable NIC Mbps/pps are mean real-NIC rates carried during confirmed windows, "
    "calibration context only; bounded cells fail with named reasons; "
    "fixtures and local captures never qualify a provider."
)
DEFAULT_PROFILES: Final = [
    {"bitrate_mbps": 6, "links": 2},
    {"bitrate_mbps": 6, "links": 4},
    {"bitrate_mbps": 10, "links": 4},
]


def settings(config: JsonMap) -> JsonMap:
    if config.get("rule") != "v3" or config.get("mode") != "ramp":
        raise ValueError("H1 v3 requires explicit rule v3 and mode ramp")
    start = integer(config.get("start_bonds", 5), positive=True)
    increment = integer(config.get("increment", 5), positive=True)
    maximum = integer(config.get("max_bonds", 200), positive=True)
    step = integer(config.get("step_s", 300), positive=True)
    warmup = integer(config.get("warmup_s", 600))
    confirmation = integer(config.get("confirmation_s", 1800), positive=True)
    if maximum > 200 or maximum < start or (maximum - start) % increment:
        raise ValueError("max_bonds must be a reachable step between start_bonds and 200")
    if step < 20 or step % 10 or warmup < 600 or warmup % 10 or confirmation < 1800 or confirmation % 10:
        raise ValueError("use 10s intervals, step_s >=20, warmup_s >=600, confirmation_s >=1800")
    profiles = []
    for raw in rows(config.get("profiles", DEFAULT_PROFILES)):
        profile = mapping(raw)
        profiles.append({
            "bitrate_mbps": integer(profile["bitrate_mbps"], positive=True),
            "links": integer(profile["links"], positive=True),
        })
    if len({(p["bitrate_mbps"], p["links"]) for p in profiles}) != len(profiles):
        raise ValueError("duplicate ramp profile")
    limits = mapping(config.get("thresholds", {}))
    if set(limits) - {"srt_drop_packets", "srt_loss_packets"}:
        raise ValueError("only SRT drop/loss thresholds are configurable in rule v3")
    return {
        "profiles": profiles, "start_bonds": start, "increment": increment, "max_bonds": maximum,
        "step_s": step, "warmup_s": warmup, "confirmation_s": confirmation,
        "thresholds": {
            "goodput_fraction": 0.98, "offered_tolerance_fraction": 0.05,
            "srt_drop_packets": integer(limits.get("srt_drop_packets", 0)),
            "srt_loss_packets": integer(limits.get("srt_loss_packets", 0)),
            "core_cpu_pct": 95, "core_sample_fraction": 0.5,
            "udp_rcvbuf_errors": 0, "udp_sndbuf_errors": 0,
            "publisher_failures": 0, "disconnects": 0,
            "sample_s": 10, "confirmation_fraction": 0.8, "confirmation_attempts": 2,
        },
    }


def judge(cell: JsonMap, limits: JsonMap, duration: int) -> JsonMap:
    """Judge interval observations, never a peak CPU substituted for occupancy."""
    if "failure" in cell:
        return {"pass": False, "reasons": [cell["failure"]], "metrics": cell}
    samples = [mapping(raw) for raw in rows(cell["samples"])]
    times = [number(s["elapsed_s"]) for s in samples]
    if len(times) != duration // 10 + 1 or times[0] > 1 or any(
        abs((b - a) - 10) > 1 for a, b in zip(times, times[1:])
    ) or times[-1] < duration:
        raise ValueError("ramp samples must cover the requested window every 10s")
    cores = [[number(v) for v in rows(s["per_core_cpu_pct"])] for s in samples[1:]]
    if len({len(v) for v in cores}) != 1 or max(max(v) for v in cores) > 100:
        raise ValueError("invalid ramp CPU topology or percentages")
    deltas = {}
    for key in ("srt_drop_packets", "srt_loss_packets", "udp_rcvbuf_errors", "udp_sndbuf_errors"):
        values = [integer(s[key]) for s in samples]
        if any(b < a for a, b in zip(values, values[1:])):
            raise ValueError("ramp counter reset")
        deltas[key] = values[-1] - values[0]
    offered = number(cell["offered_goodput_mbps"])
    delivered = number(cell["delivered_goodput_mbps"])
    target = integer(cell["bonds"], positive=True) * integer(cell["bitrate_mbps"], positive=True)
    checks = {
        "goodput": offered > 0 and delivered >= offered * number(limits["goodput_fraction"]),
        "offered_load": abs(offered - target) <= target * number(limits["offered_tolerance_fraction"]),
        "cpu": all(
            sum(v[core] >= number(limits["core_cpu_pct"]) for v in cores)
            <= len(cores) * number(limits["core_sample_fraction"])
            for core in range(len(cores[0]))
        ),
        "publishers": integer(cell["publisher_failures"]) == 0,
        "disconnects": integer(cell["disconnects"]) == 0,
        **{key: delta <= number(limits[key]) for key, delta in deltas.items()},
    }
    return {
        "pass": all(checks.values()), "checks": checks,
        "reasons": [key for key, ok in checks.items() if not ok],
        "counter_deltas": deltas, "metrics": cell,
    }


def rss_check(cell: JsonMap, stock: JsonMap, warmup: int) -> JsonMap:
    """The v2 predicate at matching retained indices; ten-second capture cadence."""
    samples = [mapping(s) for s in rows(cell["samples"])]
    baseline = [mapping(s) for s in rows(stock["samples"])]
    first = next(i for i, s in enumerate(samples) if number(s["elapsed_s"]) >= warmup)
    rss = [number(s["rss_bytes"]) for s in samples[first:]]
    reference = [number(s["rss_bytes"]) for s in baseline[first:]]
    window = number(samples[-1]["elapsed_s"]) - number(samples[first]["elapsed_s"])
    growth = rss[-1] > rss[0] and all(b >= a for a, b in zip(rss, rss[1:]))
    ok = not growth or rss[-1] - rss[0] <= reference[-1] - reference[0]
    return {
        "pass": ok and window >= 1800, "warmup_s": warmup,
        "start_s": samples[first]["elapsed_s"], "duration_s": window,
        "reason": "post_warmup_window_too_short" if window < 1800 else
        "monotonic_growth_exceeds_stock" if not ok else "pass",
    }


def carried(cell: JsonMap, warmup: int) -> tuple[JsonMap, JsonMap]:
    samples = [mapping(s) for s in rows(cell["samples"]) if number(mapping(s)["elapsed_s"]) >= warmup]
    elapsed = number(samples[-1]["elapsed_s"]) - number(samples[0]["elapsed_s"])
    before, after = (rows(s["nic"]) for s in (samples[0], samples[-1]))
    rates = [(number(b) - number(a)) / elapsed for a, b in zip(before, after)]
    if len(rates) != 4 or min(rates) <= 0:
        raise ValueError("confirmed NIC counters must carry traffic in both directions")
    return {"in": rates[0] * 8 / 1e6, "out": rates[1] * 8 / 1e6}, {"in": rates[2], "out": rates[3]}


Collect = Callable[[int, JsonMap, int, str], JsonMap]


def campaign(config: JsonMap, collect: Collect) -> JsonMap:
    options = settings(config)
    limits = mapping(options["thresholds"])
    profiles = []
    for raw in rows(options["profiles"]):
        profile = mapping(raw)
        label = f'{profile["bitrate_mbps"]}-{profile["links"]}'
        steps, attempts = [], []
        ceiling, confirmed = 0, 0
        nic, pps = {}, {}
        maximum = integer(options["max_bonds"])
        increment = integer(options["increment"])
        for count in range(integer(options["start_bonds"]), maximum + 1, increment):
            duration = integer(options["step_s"])
            step = judge(collect(count, profile, duration, f"ramp-{label}-{count}"), limits, duration)
            steps.append(step)
            if not step["pass"]:
                break
            ceiling = count
        candidate = 4 * ceiling // 5
        # One extra interval ensures actual retained timestamps span >=1800s.
        duration = integer(options["warmup_s"]) + integer(options["confirmation_s"]) + 10
        for attempt in range(2):
            if candidate <= 0:
                break
            prefix = f"confirm-{label}-{candidate}-{attempt + 1}"
            stock = collect(candidate, profile, duration, prefix + "-stock")
            stock_result = judge(stock, limits, duration)
            record = {"bonds": candidate, "stock": stock_result, "pass": False}
            if stock_result["pass"]:
                cell = collect(candidate, profile, duration, prefix)
                measured = judge(cell, limits, duration)
                record["measured"] = measured
                if measured["pass"]:
                    rss = rss_check(cell, stock, integer(options["warmup_s"]))
                    record["rss_window"] = rss
                    record["pass"] = rss["pass"]
                    if rss["pass"]:
                        nic, pps = carried(cell, integer(options["warmup_s"]))
                        confirmed = candidate
            attempts.append(record)
            if confirmed:
                break
            candidate -= increment
        profiles.append({
            **profile, "steps": steps, "ceiling": ceiling,
            "ceiling_relation": ">=" if ceiling == maximum else "=",
            "confirmation_attempts": attempts, "confirmed_bonds": confirmed,
            "sustainable_nic_mbps": nic, "sustainable_pps": pps,
        })
    cap = min(integer(p["confirmed_bonds"]) for p in profiles)
    return {
        "scenario": "H1", "rule_version": "v3", "rule_sha256": hashlib.sha256(RULE_V3.encode()).hexdigest(),
        "source": "fixture", "qualified": False, "winner": "fixture_capacity" if cap else "insufficient",
        "provider_class": config["provider_class"], "options": options,
        "thresholds": limits, "profiles": profiles, "softCapBonds": cap, "maxAssignedRelays": 2 * cap,
        "sustainable_nic_mbps": {
            key: min(number(mapping(p["sustainable_nic_mbps"])[key]) for p in profiles)
            for key in ("in", "out")
        } if cap else {},
        "sustainable_pps": {
            key: min(number(mapping(p["sustainable_pps"])[key]) for p in profiles)
            for key in ("in", "out")
        } if cap else {},
    }


def evaluate(value: Json) -> JsonMap:
    document = fixture_document(value)
    if document.get("sender_ref") != "main" or document.get("receiver") != "stock":
        raise ValueError("H1 v3 requires unchanged main sender and stock receiver")
    cells = iter(rows(document["cells"]))

    def collect(count: int, profile: JsonMap, duration: int, label: str) -> JsonMap:
        cell = mapping(next(cells, None))
        if any(cell.get(k) != v for k, v in {
            "bonds": count, **profile, "duration_s": duration, "label": label,
        }.items()):
            raise ValueError("fixture cell does not match the ramp schedule")
        return cell

    result = campaign(document, collect)
    if next(cells, None) is not None:
        raise ValueError("unused ramp fixture cells")
    return result

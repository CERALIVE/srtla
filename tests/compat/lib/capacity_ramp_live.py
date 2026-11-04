"""Bounded v3 orchestration over the existing H1 remote generator and NIC capture."""

from __future__ import annotations

import hashlib
import json
import re
import signal
import subprocess
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator

from benchmark_fixture_io import JsonMap, integer, mapping, number, text
from benchmark_live import Processes, PrerequisiteError, argv, require_tool
from capacity_generator_processes import reap
from capacity_live import calibrate, cpu_usage, measure
from capacity_ramp import campaign, settings
from capacity_remote import Generator


class StepTimeout(TimeoutError):
    """A v3 cell exceeded its recorded wall-clock work budget."""


@contextmanager
def deadline(seconds: float) -> Iterator[None]:
    """Interrupt even a blocked control write/read; cleanup has separate bounds."""
    def expired(_signum, _frame) -> None:
        raise StepTimeout("step_timeout")

    previous = signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


@contextmanager
def cleanup_window() -> Iterator[None]:
    """Do not interrupt a bounded kill/reap sweep with the work deadline."""
    remaining, interval = signal.setitimer(signal.ITIMER_REAL, 0)
    started = time.monotonic()
    try:
        yield
    finally:
        if remaining:
            signal.setitimer(signal.ITIMER_REAL, max(0.001, remaining - (time.monotonic() - started)), interval)


class RampProcesses(Processes):
    def close(self) -> None:
        if not self.closed:
            with cleanup_window():
                reap(self)


class RampGenerator(Generator):
    def close(self) -> None:
        with cleanup_window():
            super().close()


def udp_buffers() -> JsonMap:
    lines = Path("/proc/net/snmp").read_text().splitlines()
    for index, line in enumerate(lines):
        if line.startswith("Udp: InDatagrams "):
            values = dict(zip(line.split()[1:], lines[index + 1].split()[1:]))
            return {
                "udp_rcvbuf_errors": int(values["RcvbufErrors"]),
                "udp_sndbuf_errors": int(values["SndbufErrors"]),
            }
    raise RuntimeError("missing_udp_buffer_counters")


def srt_stats(config: JsonMap, directory: Path, count: int, index: int) -> JsonMap:
    """Read actual receiver-side cumulative SRT counters, never assumed zeros."""
    with RampProcesses() as processes:
        child = processes.start(
            argv(mapping(config["srt_stats"]), {"bonds": count, "directory": str(directory)}),
            directory / f"srt-stats-{index}.json", stdin=subprocess.DEVNULL,
        )
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            raise RuntimeError("srt_stats_timeout") from None
        if child.returncode:
            raise RuntimeError(f"srt_stats_exited:{child.returncode}")
    result = mapping(json.loads((directory / f"srt-stats-{index}.json").read_text()))
    for key in ("pkt_rcv_drop", "pkt_rcv_loss", "publishers", "disconnects"):
        integer(result[key])
    if result["publishers"] != count:
        raise RuntimeError("publisher_disconnected")
    return result


def collect_cell(config: JsonMap, root: Path, count: int, profile: JsonMap, duration: int, label: str) -> JsonMap:
    directory = root / label
    directory.mkdir()
    window = {**config, "duration_s": duration, "samples": duration // 10 + 1}
    # Readiness per publisher, control round trips and evidence retirement are
    # included in the work budget; every cleanup wait is independently bounded.
    timeout = number(config.get("step_timeout_s", duration + 30 * count + 120), positive=True)
    samples = []
    raw_previous = None

    def observe(raw: JsonMap) -> None:
        nonlocal raw_previous
        stats = srt_stats(config, directory, count, len(samples))
        cpu = cpu_usage(raw_previous["cpu"], raw["cpu"]) if raw_previous is not None else [0] * len(raw["cpu"])
        sample = {
            "elapsed_s": raw["elapsed_s"], "per_core_cpu_pct": cpu, "nic": raw["nic"],
            "rss_bytes": raw["rss_bytes"], **udp_buffers(),
            "srt_drop_packets": stats["pkt_rcv_drop"], "srt_loss_packets": stats["pkt_rcv_loss"],
            "srt_disconnects": stats["disconnects"], "srt_stats": stats, "capture": raw,
        }
        samples.append(sample)
        raw_previous = raw
        with (directory / "progress.jsonl").open("a") as output:
            output.write(json.dumps(sample, allow_nan=False) + "\n")
        print(json.dumps({"event": "sample", "cell": label, "elapsed_s": raw["elapsed_s"]}), flush=True)

    base = {
        "label": label, "bonds": count, **profile, "duration_s": duration,
        "step_timeout_s": timeout, "samples": samples,
        "cleanup_bounds": {
            "local_process_wait_s": 5, "local_reader_join_s": 5,
            "generator_channel_wait_s": 5 * (3 * 200 + 2) + 30,
            "generator_kill_wait_s": 5,
        },
    }
    print(json.dumps({"event": "cell_start", "cell": label, "step_timeout_s": timeout}), flush=True)
    try:
        with deadline(timeout), RampGenerator(window, directory) as generator:
            measured = measure(
                window, directory / "capture", count, integer(profile["bitrate_mbps"]),
                integer(profile["links"]), generator=generator, observe=observe, process_owner=RampProcesses,
            )
            result = {
                **base, "offered_goodput_mbps": measured["offered_goodput_mbps"],
                "delivered_goodput_mbps": measured["delivered_goodput_mbps"],
                "publisher_failures": 0,
                "disconnects": measured["disconnects"] + (
                    integer(samples[-1]["srt_disconnects"]) - integer(samples[0]["srt_disconnects"])
                ),
                "generator_provenance": generator.provenance,
            }
            generator.retire(directory / "capture", result)
    except PrerequisiteError:
        raise
    except (TimeoutError, RuntimeError, subprocess.SubprocessError) as error:
        reason = "step_timeout" if isinstance(error, StepTimeout) else str(error)
        result = {**base, "failure": reason}
    (directory / "cell.json").write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
    print(json.dumps({"event": "cell_end", "cell": label, "failure": result.get("failure")}), flush=True)
    return result


def capture(config: JsonMap, directory: Path) -> JsonMap:
    options = settings(config)
    for key in ("generator", "srt_stats", "interface", "provider_class", "receiver", "sender", "sls", "sink", "load", "calibration"):
        if key not in config:
            raise PrerequisiteError(f"missing_h1_v3_config:{key}")
    if config.get("sender_ref") != "main" or not re.fullmatch(r"[a-f0-9]{40}", text(config["sender_sha"])):
        raise ValueError("H1 v3 requires unchanged main sender with a 40-character source SHA")
    receiver = require_tool(text(config["receiver"]))
    interface = text(config["interface"])
    if interface == "lo" or not Path(f"/sys/class/net/{interface}/device").exists():
        raise PrerequisiteError("h1_v3_requires_real_nic")
    calibration_dir = directory / "calibration"
    calibration_dir.mkdir()
    peer = mapping(config["calibration"])
    budget = 2 * len(peer["offered_mbps"]) * (integer(peer.get("duration_s", 30), positive=True) + 30) + 120
    calibration_config = {**config, "duration_s": options["step_s"], "samples": integer(options["step_s"]) // 10 + 1}
    with deadline(budget), RampGenerator(calibration_config, calibration_dir) as generator:
        if mapping(config["generator"]).get("calibration_peer"):
            generator.request("iperf")
        try:
            nic, pps, calibration = calibrate(config, calibration_dir)
        finally:
            if mapping(config["generator"]).get("calibration_peer"):
                generator.request("stop")
        provenance = generator.provenance

    def collect(count: int, profile: JsonMap, duration: int, label: str) -> JsonMap:
        return collect_cell(config, directory, count, profile, duration, label)

    result = campaign(config, collect)
    result.update({
        "source": "real-host", "winner": "measured_capacity" if result["softCapBonds"] else "insufficient",
        "status": "MEASURED", "sender_sha": config["sender_sha"],
        "sender_binary_sha256": provenance["sender_binary_sha256"],
        "receiver_binary_sha256": hashlib.sha256(Path(receiver).read_bytes()).hexdigest(),
        "calibration": {"sustainable_nic_mbps": nic, "sustainable_pps": pps, "trials": calibration, "context_only": True},
        "qualification_limit": "local capture is not the owner-gated Miami campaign",
    })
    (directory / "measurements.json").write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
    return result

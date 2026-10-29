"""H1 real process/NIC capture; never creates hosts or changes capacity settings."""

from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import threading
import time
import urllib.request
from itertools import product
from pathlib import Path

from benchmark_fixture_io import JsonMap, integer, mapping, number, rows, text
from benchmark_live import Processes, PrerequisiteError, argv, port, require_tool
from capacity_probe import evaluate


def counter_rates(before: list[int], after: list[int], elapsed: float) -> list[float]:
    if elapsed <= 0 or len(before) != len(after) or any(b < a for a, b in zip(before, after)):
        raise ValueError("counter reset or invalid sample window")
    return [(b - a) / elapsed for a, b in zip(before, after)]


def cpu_usage(before: list[list[int]], after: list[list[int]]) -> list[float]:
    usage = []
    if len(before) != len(after):
        raise ValueError("CPU topology changed during capture")
    for a, b in zip(before, after):
        delta = [y - x for x, y in zip(a, b)]
        # guest/guest_nice are already included in user/nice.
        total = sum(delta[:8])
        if total <= 0 or min(delta) < 0:
            raise ValueError("invalid CPU counter interval")
        usage.append(100 * (total - delta[3] - delta[4]) / total)
    return usage


def cpu_counters() -> list[list[int]]:
    return [
        [int(v) for v in line.split()[1:]]
        for line in Path("/proc/stat").read_text().splitlines()
        if re.match(r"cpu\d+ ", line)
    ]


def parse_nic_counters(content: str, interface: str) -> list[int]:
    if not re.fullmatch(r"[a-zA-Z0-9_.:-]+", interface):
        raise ValueError("invalid interface")
    for line in content.splitlines()[2:]:
        name, raw = line.rsplit(":", 1)
        if name.strip() == interface:
            counters = [int(value) for value in raw.split()]
            return [counters[0], counters[8], counters[1], counters[9]]
    raise PrerequisiteError(f"missing_nic:{interface}")


def nic_counters(interface: str) -> list[int]:
    # sysfs may still be mounted for the host's netns after unshare.
    return parse_nic_counters(Path("/proc/net/dev").read_text(), interface)


def udp_errors() -> int:
    lines = Path("/proc/net/snmp").read_text().splitlines()
    for index, line in enumerate(lines):
        if line.startswith("Udp: InDatagrams "):
            values = dict(zip(line.split()[1:], lines[index + 1].split()[1:]))
            return int(values["InErrors"])
    raise RuntimeError("missing_udp_snmp_counters")


def process_ticks(pid: int) -> int:
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    return int(fields[11]) + int(fields[12])


def metrics(url: str) -> dict[str, float]:
    with urllib.request.urlopen(url, timeout=5) as response:
        content = response.read().decode()
    return {
        line.rsplit(" ", 1)[0]: float(line.rsplit(" ", 1)[1])
        for line in content.splitlines() if line and not line.startswith("#")
    }


def iperf_result(document: dict, maximum_loss: float) -> tuple[float, float]:
    if "error" in document:
        raise RuntimeError(f"iperf_failed:{document['error']}")
    end = document["end"]
    received = end.get("sum_received", end.get("sum"))
    if received is None:
        raise ValueError("iperf result has no receiver counters")
    seconds = number(received["seconds"], positive=True)
    packets = integer(received["packets"], positive=True)
    lost = integer(received["lost_packets"])
    if lost > packets or 100 * lost / packets > maximum_loss:
        return 0, 0
    return number(received["bits_per_second"]) / 1e6, (packets - lost) / seconds


def calibrate(config: dict, directory: Path) -> tuple[dict, dict, list[dict]]:
    tool = require_tool("iperf3")
    peer = mapping(config["calibration"])
    host = text(peer["host"])
    service_port = port(integer(peer["port"]))
    duration = integer(peer.get("duration_s", 30), positive=True)
    maximum_loss = number(peer.get("maximum_loss_pct", 0.1))
    interface = text(config["interface"])
    ceilings = {"in": 0.0, "out": 0.0}
    packets = {"in": 0.0, "out": 0.0}
    evidence = []
    for direction in ("in", "out"):
        for offered in rows(peer["offered_mbps"]):
            bitrate = number(offered, positive=True)
            command = [
                tool, "-c", host, "-p", str(service_port), "-u", "-b", f"{bitrate}M",
                "-l", "1316", "-t", str(duration), "-J", "--get-server-output",
            ]
            if direction == "in":
                command.append("-R")
            before, started = nic_counters(interface), time.monotonic()
            completed = subprocess.run(command, capture_output=True, text=True, check=True, timeout=duration + 30)
            elapsed = time.monotonic() - started
            after = nic_counters(interface)
            raw = json.loads(completed.stdout)
            rate, pps = iperf_result(raw, maximum_loss)
            nic = counter_rates(before, after, elapsed)
            index = 0 if direction == "in" else 1
            # Never exceed either delivered load or the actual interface counters.
            rate = min(rate, nic[index] * 8 / 1e6)
            pps = min(pps, nic[index + 2])
            if rate > ceilings[direction]:
                ceilings[direction], packets[direction] = rate, pps
            record = {
                "direction": direction, "offered_mbps": bitrate, "elapsed_s": elapsed,
                "nic_rates": nic, "delivered_mbps": rate, "delivered_pps": pps, "iperf": raw,
            }
            evidence.append(record)
            (directory / f"nic-{direction}-{bitrate:g}.json").write_text(json.dumps(record, indent=2) + "\n")
        if not ceilings[direction] or not packets[direction]:
            raise RuntimeError(f"no_sustainable_calibration:{direction}")
    return ceilings, packets, evidence


def measure(
    config: dict, directory: Path, bonds: int, bitrate: int, links: int,
) -> dict:
    directory.mkdir()
    duration = number(config.get("duration_s", 1800), positive=True)
    samples = integer(config.get("samples", 31), positive=True)
    if samples < 3:
        raise ValueError("capture requires at least three samples")
    base = port(integer(config.get("port_base", 43100)))
    port(base + 10 + bonds)
    interface = text(config["interface"])
    addresses = [text(v) for v in rows(config["link_addresses"])]
    if len(addresses) < links:
        raise PrerequisiteError(f"missing_uplink_addresses:need_{links}")
    ips = directory / "ips.txt"
    ips.write_text("\n".join(addresses[:links]) + "\n")
    receiver_core = integer(config.get("receiver_core", min(os.sched_getaffinity(0))))
    variables = {
        "receiver_port": base, "metrics_port": base + 1, "sls_port": base + 2,
        "ips_file": str(ips), "bitrate_mbps": bitrate, "duration_s": duration,
        "directory": str(directory),
    }
    receiver = require_tool(text(config["receiver"]))
    with Processes() as processes:
        sls_config = mapping(config["sls"])
        sls = processes.start(
            argv(sls_config, variables), directory / "sls.log", sls_config.get("ready"),
        )
        receiver_process = processes.start([
            require_tool("taskset"), "-c", str(receiver_core), receiver,
            "--srtla_port", str(base), "--srt_hostname", text(config.get("sls_host", "127.0.0.1")),
            "--srt_port", str(base + 2), "--metrics_bind", "127.0.0.1",
            "--metrics_port", str(base + 1), "--log_level", "info",
        ], directory / "receiver.log", "srtla_rec is now running")
        outputs = []
        loads = []
        for bond in range(bonds):
            media = directory / f"delivered-{bond}.ts"
            outputs.append(media)
            bond_variables = {**variables, "bond": bond, "local_port": base + 10 + bond, "media_file": str(media)}
            sink_config = mapping(config["sink"])
            processes.start(argv(sink_config, bond_variables), directory / f"sink-{bond}.log")
            sender_config = mapping(config["sender"])
            processes.start(argv(sender_config, bond_variables), directory / f"sender-{bond}.log")
            load_config = mapping(config["load"])
            loads.append(processes.start(
                argv(load_config, bond_variables), directory / f"load-{bond}.log", text(load_config["ready"]),
            ))
        url = f"http://127.0.0.1:{base + 1}/metrics"
        counters: dict[str, list] = {
            key: [] for key in ("packets_received", "recv_batches", "udp_receive_errors", "rss_bytes", "fd_count")
        }
        snapshots = []
        before_cpu, before_nic = cpu_counters(), nic_counters(interface)
        before_sls = process_ticks(sls.pid)
        before_receiver = process_ticks(receiver_process.pid)
        before_bytes = sum(p.stat().st_size if p.exists() else 0 for p in outputs)
        if any(child.pid not in processes.bytes for child in loads):
            raise RuntimeError("missing_load_byte_progress:emit ffmpeg -progress pipe:1 total_size")
        before_load = sum(processes.bytes[child.pid] for child in loads)
        started = previous = time.monotonic()
        first_metrics = metrics(url)
        peak_cpu = [0.0] * len(before_cpu)
        peak_nic = [0.0] * 4
        peak_sls = 0.0
        peak_receiver = 0.0
        finished_metrics = first_metrics
        for sample in range(samples):
            if sample:
                threading.Event().wait(max(0, started + duration * sample / (samples - 1) - time.monotonic()))
            processes.alive()
            now = time.monotonic()
            current_cpu, current_nic = cpu_counters(), nic_counters(interface)
            current_sls = process_ticks(sls.pid)
            current_receiver = process_ticks(receiver_process.pid)
            finished_metrics = metrics(url)
            status = Path(f"/proc/{receiver_process.pid}/status").read_text()
            rss = int(re.search(r"^VmRSS:\s+(\d+)", status, re.MULTILINE)[1]) * 1024
            fds = len(list(Path(f"/proc/{receiver_process.pid}/fd").iterdir()))
            for key, value in (
                ("packets_received", finished_metrics["srtla_packets_received_total"]),
                ("recv_batches", finished_metrics["srtla_recv_batches_total"]),
                ("udp_receive_errors", udp_errors()), ("rss_bytes", rss), ("fd_count", fds),
            ):
                counters[key].append(value)
            if sample:
                cpu = cpu_usage(before_cpu, current_cpu)
                nic = counter_rates(before_nic, current_nic, now - previous)
                peak_cpu = [max(a, b) for a, b in zip(peak_cpu, cpu)]
                peak_nic = [max(a, b) for a, b in zip(peak_nic, nic)]
                peak_sls = max(peak_sls, min(100, 100 * (current_sls - before_sls) / os.sysconf("SC_CLK_TCK") / (now - previous)))
                peak_receiver = max(peak_receiver, min(100, 100 * (current_receiver - before_receiver) / os.sysconf("SC_CLK_TCK") / (now - previous)))
            snapshots.append({
                "elapsed_s": now - started, "nic": current_nic, "cpu": current_cpu,
                "sls_ticks": current_sls, "receiver_ticks": current_receiver,
                "metrics": finished_metrics, "rss_bytes": rss, "fds": fds,
            })
            before_cpu, before_nic, before_sls, previous = current_cpu, current_nic, current_sls, now
            before_receiver = current_receiver
        elapsed = time.monotonic() - started
        delivered = (sum(p.stat().st_size if p.exists() else 0 for p in outputs) - before_bytes) * 8 / 1e6 / elapsed
        offered = (sum(processes.bytes[child.pid] for child in loads) - before_load) * 8 / 1e6 / elapsed
        (directory / "samples.json").write_text(json.dumps(snapshots, indent=2) + "\n")
        def removed(reason: str) -> float:
            key = f'srtla_groups_removed_total{{reason="{reason}"}}'
            return finished_metrics[key] - first_metrics[key]
        return {
            "bonds": bonds, "bitrate_mbps": bitrate, "links": links, "duration_s": elapsed,
            "per_core_cpu_pct": peak_cpu, "receiver_core": receiver_core,
            "nic_in_mbps": peak_nic[0] * 8 / 1e6, "nic_out_mbps": peak_nic[1] * 8 / 1e6,
            "pps_in": peak_nic[2], "pps_out": peak_nic[3], "sls_cpu_pct": peak_sls,
            "receiver_cpu_pct": peak_receiver,
            "delivered_goodput_mbps": delivered,
            "offered_goodput_mbps": offered,
            "auth_failures": finished_metrics["srtla_auth_failures_total"] - first_metrics["srtla_auth_failures_total"],
            "evictions": removed("evicted"),
            "disconnects": removed("idle_timeout") + removed("srt_error") + removed("auth_failed"),
            **counters,
        }


def preview_trials(config: dict, directory: Path) -> list[dict]:
    preview = mapping(config["preview"])
    duration = number(config.get("duration_s", 1800), positive=True)
    results = []
    for raw_count in rows(preview["counts"]):
        count = integer(raw_count, positive=True)
        with Processes() as processes:
            children = [
                processes.start(
                    argv(preview, {"index": index, "directory": str(directory)}),
                    directory / f"preview-{count}-{index}.log", "frame=",
                )
                for index in range(count)
            ]
            before = cpu_counters()
            frames = [processes.frames.get(child.pid, 0) for child in children]
            started = previous = time.monotonic()
            cpu, fps = 0.0, float("inf")
            samples = integer(config.get("samples", 31), positive=True)
            for sample in range(1, samples):
                threading.Event().wait(max(0, started + duration * sample / (samples - 1) - time.monotonic()))
                processes.alive()
                now = time.monotonic()
                after = cpu_counters()
                current = [processes.frames.get(child.pid, 0) for child in children]
                cpu = max(cpu, max(cpu_usage(before, after)))
                fps = min(fps, min((b - a) / (now - previous) for a, b in zip(frames, current)))
                before, frames, previous = after, current, now
            results.append({"transcodes": count, "duration_s": previous - started, "cpu_pct": cpu, "minimum_fps": fps})
    return results


def capture(config: JsonMap, directory: Path) -> JsonMap:
    for key in ("interface", "provider_class", "receiver", "sender", "sls", "sink", "load", "preview", "calibration", "link_addresses"):
        if key not in config:
            raise PrerequisiteError(f"missing_h1_config:{key}")
    if config.get("sender_ref") != "main":
        raise ValueError("H1 sender_ref must be main")
    if not re.fullmatch(r"[a-f0-9]{40}", text(config["sender_sha"])):
        raise ValueError("sender_sha must identify the unchanged main source")
    nic, pps, calibration = calibrate(config, directory)
    cells = []
    for count in rows(config.get("bonds", [1, 25, 50, 100, 150, 200])):
        bonds = integer(count, positive=True)
        if bonds > 200:
            raise ValueError("H1 supports at most 200 bonds")
        for bitrate, links in product((6, 10, 20), (1, 4, 16)):
            label = f"{bonds}-{bitrate}-{links}"
            baseline = measure(config, directory / (label + "-stock"), bonds, bitrate, links)
            cell = measure(config, directory / label, bonds, bitrate, links)
            cell["stock_rss_bytes"] = baseline["rss_bytes"]
            cell["baseline_goodput_mbps"] = baseline["delivered_goodput_mbps"]
            if not cell["baseline_goodput_mbps"]:
                raise RuntimeError(f"no_delivered_stock_media:{label}")
            cells.append(cell)
    # Per-bond packets are measured at the six-Mbps, single-uplink load.
    six = next(cell for cell in cells if cell["bitrate_mbps"] == 6 and cell["links"] == 1)
    per_bond_pps = (six["packets_received"][-1] - six["packets_received"][0]) / six["duration_s"] / six["bonds"]
    measured = {
        "schema_version": 1, "source": "real-host", "provider_class": config["provider_class"],
        "sender_ref": "main", "receiver": "stock", "sustainable_nic_mbps": nic,
        "sustainable_pps": pps, "per_bond_pps_6mbps": per_bond_pps,
        "cells": cells, "preview_trials": preview_trials(config, directory),
    }
    result = evaluate(measured, captured=True)
    (directory / "measurements.json").write_text(json.dumps(measured, indent=2) + "\n")
    result.update({
        "source": "real-host", "qualified": False,
        "winner": "measured_capacity" if result["softCapBonds"] else "insufficient",
        "status": "MEASURED", "calibration": calibration,
        "sender_sha": config["sender_sha"],
        "sender_binary_sha256": hashlib.sha256(Path(require_tool(text(mapping(config["sender"])["argv"][0]))).read_bytes()).hexdigest(),
        "receiver_binary_sha256": hashlib.sha256(Path(text(config["receiver"])).read_bytes()).hexdigest(),
        "qualification_limit": "local capture is not the owner-gated Miami campaign",
    })
    return result

#!/usr/bin/env python3
"""Foreground H1 generator worker. Run through an explicit SSH command array."""

from __future__ import annotations

import hashlib
import ipaddress
import json
import os
import queue
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from benchmark_fixture_io import JsonMap, integer, mapping, number, text
from benchmark_live import Processes, PrerequisiteError, argv, port, require_tool


class Worker:
    """Accumulate owned generator groups and counters for one cell at a time."""

    def __init__(self) -> None:
        self.processes = Processes()
        self.config: JsonMap = {}
        self.directory: Path | None = None
        self.loads = []
        self.outputs: list[Path] = []
        self.begin: JsonMap | None = None
        self.last: JsonMap | None = None
        self.lease = 90.0

    def hello(self, config: JsonMap) -> JsonMap:
        self.config = config
        generator = mapping(config["generator"])
        for key in ("source_address", "receiver_host"):
            address = ipaddress.ip_address(text(generator[key]))
            if address.is_loopback or address.is_unspecified:
                raise ValueError(f"generator_requires_routed_address:{key}")
        samples = integer(config.get("samples", 31), positive=True)
        if samples < 3:
            raise ValueError("capture requires at least three samples")
        self.measurement_lease = number(config.get("duration_s", 1800), positive=True) / (samples - 1) + 90
        calibration = mapping(config["calibration"])
        calibration_window = 2 * len(calibration.get("offered_mbps", [])) * (
            integer(calibration.get("duration_s", 30), positive=True) + 30
        )
        self.lease = max(self.measurement_lease, calibration_window + 90)
        sender = require_tool(text(mapping(config["sender"])["argv"][0]))
        return {
            "sender_sha": config["sender_sha"],
            "sender_binary_sha256": hashlib.sha256(Path(sender).read_bytes()).hexdigest(),
            "harness_sha256": {
                path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                for path in (Path(__file__), Path(__file__).with_name("capacity_remote.py"),
                             Path(__file__).with_name("benchmark_live.py"),
                             Path(__file__).with_name("capacity_live.py"))
            },
            "host": os.uname().nodename, "source_address": generator["source_address"],
        }

    def prepare(self, request: JsonMap) -> JsonMap:
        from capacity_live import media_space

        generator = mapping(self.config["generator"])
        root = Path(text(generator["directory"]))
        bonds, bitrate, links = (integer(request[key], positive=True) for key in ("bonds", "bitrate", "links"))
        duration = number(self.config.get("duration_s", 1800), positive=True)
        media_space(root, bonds, bitrate, duration)
        self.directory = Path(tempfile.mkdtemp(prefix="h1-" + text(request["label"]) + "-", dir=root))
        base = port(integer(self.config.get("port_base", 43100)))
        port(base + 10 + bonds)
        ips = self.directory / "ips.txt"
        # A fresh sender opens distinct ephemeral sockets; never reload this list.
        ips.write_text((text(generator["source_address"]) + "\n") * links)
        variables = {
            "receiver_port": base, "metrics_port": base + 1, "sls_port": base + 2,
            "receiver_host": text(generator["receiver_host"]), "ips_file": str(ips),
            "bitrate_mbps": bitrate, "duration_s": duration, "directory": str(self.directory),
        }
        self.loads, self.outputs, self.begin, self.last = [], [], None, None
        for bond in range(bonds):
            media = self.directory / f"delivered-{bond}.ts"
            self.outputs.append(media)
            values = {**variables, "bond": bond, "local_port": base + 10 + bond, "media_file": str(media)}
            self.processes.start(
                argv(mapping(self.config["sender"]), values), self.directory / f"sender-{bond}.log",
                stdin=subprocess.DEVNULL,
            )
            load = mapping(self.config["load"])
            self.loads.append(self.processes.start(
                argv(load, values), self.directory / f"load-{bond}.log",
                text(load["ready"]), byte_progress=True, stdin=subprocess.DEVNULL,
            ))
            sink = mapping(self.config["sink"])
            self.processes.start(
                argv(sink, values), self.directory / f"sink-{bond}.log", sink.get("ready"),
                stdin=subprocess.DEVNULL,
            )
        self.processes.alive()
        self.lease = self.measurement_lease
        return {
            "directory": str(self.directory), "host": os.uname().nodename,
            "pids": [child.pid for child in self.processes.children],
        }

    def snapshot(self) -> JsonMap:
        self.processes.alive()
        if any(child.pid not in self.processes.bytes for child in self.loads):
            raise RuntimeError("missing_load_byte_progress:generator")
        offered = [self.processes.bytes[child.pid] for child in self.loads]
        delivered = [path.stat().st_size if path.exists() else 0 for path in self.outputs]
        snapshot = {
            "monotonic_s": time.monotonic(),
            "offered_bytes": sum(offered), "delivered_bytes": sum(delivered),
            "offered_bytes_by_bond": offered, "delivered_bytes_by_bond": delivered,
        }
        if self.last is not None and any(
            after < before
            for key in ("offered_bytes_by_bond", "delivered_bytes_by_bond")
            for before, after in zip(self.last[key], snapshot[key])
        ):
            raise ValueError("generator_counter_reset")
        self.last = snapshot
        return snapshot

    def finish(self) -> JsonMap:
        end = self.snapshot()
        self.processes.close()
        self.processes = Processes()
        elapsed = number(end["monotonic_s"]) - number(self.begin["monotonic_s"])
        if elapsed <= 0:
            raise ValueError("invalid_generator_window")
        rates = {}
        for name in ("offered", "delivered"):
            delta = integer(end[name + "_bytes"]) - integer(self.begin[name + "_bytes"])
            if delta < 0:
                raise ValueError("generator_counter_reset")
            rates[name + "_goodput_mbps"] = delta * 8 / 1e6 / elapsed
        return {"begin": self.begin, "end": end, "elapsed_s": elapsed, **rates}

    def dispatch(self, request: JsonMap) -> JsonMap:
        match text(request["operation"]):
            case "hello":
                return self.hello(mapping(request["config"]))
            case "prepare":
                return self.prepare(request)
            case "start":
                self.begin = self.snapshot()
                return self.begin
            case "alive":
                return self.snapshot()
            case "finish":
                return self.finish()
            case "manifest":
                from capacity_live import retire_media

                manifest = retire_media(self.directory, mapping(request["verdict"]), retain=True)
                logs = {}
                for path in self.directory.glob("*.log"):
                    with path.open("rb") as source:
                        source.seek(max(0, path.stat().st_size - 65536))
                        logs[path.name] = {
                            "size_bytes": path.stat().st_size,
                            "tail": source.read().decode(errors="replace"),
                        }
                return {"manifest": manifest, "logs": logs, "host": os.uname().nodename}
            case "delete":
                for path in self.outputs:
                    path.unlink(missing_ok=True)
                return {"deleted": len(self.outputs)}
            case "iperf":
                peer = mapping(self.config["calibration"])
                root = Path(text(mapping(self.config["generator"])["directory"]))
                self.directory = Path(tempfile.mkdtemp(prefix="h1-iperf-", dir=root))
                self.processes.start([
                    require_tool("iperf3"), "-s", "--forceflush", "-p", str(port(integer(peer["port"]))),
                ], self.directory / "iperf.log", "Server listening on", stdin=subprocess.DEVNULL)
                return {"pid": self.processes.children[0].pid, "controller_lease_s": self.lease}
            case "stop":
                self.processes.close()
                self.processes = Processes()
                return {"stopped": True}
            case _:
                raise ValueError("unknown_generator_operation")


def main() -> int:
    worker = Worker()
    requests: queue.Queue = queue.Queue()

    def ignore_shutdown() -> None:
        for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            signal.signal(signum, signal.SIG_IGN)

    def terminate(_signum: int, _frame) -> None:
        ignore_shutdown()
        raise SystemExit(0)

    def receive() -> None:
        for line in sys.stdin:
            requests.put(line)
        # Wake the main thread even while it is waiting for positive progress.
        os.kill(os.getpid(), signal.SIGTERM)

    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(signum, terminate)
    threading.Thread(target=receive, daemon=True).start()
    try:
        while True:
            try:
                request = mapping(json.loads(requests.get(timeout=worker.lease)))
                response = worker.dispatch(request)
            except queue.Empty:
                raise RuntimeError("generator_controller_lease_expired") from None
            except (OSError, ValueError, KeyError, RuntimeError) as error:
                print(json.dumps({
                    "error": str(error), "prerequisite": isinstance(error, PrerequisiteError),
                    "owned_pids": [child.pid for child in worker.processes.children],
                }), flush=True)
                return 2
            print(json.dumps(response, allow_nan=False), flush=True)
    finally:
        ignore_shutdown()
        worker.processes.close()


if __name__ == "__main__":
    raise SystemExit(main())

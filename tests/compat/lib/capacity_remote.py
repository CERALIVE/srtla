"""H1 generator control channel; media never crosses this channel."""

from __future__ import annotations

import hashlib
import json
import os
import selectors
import signal
import subprocess
import time
from pathlib import Path

from benchmark_fixture_io import JsonMap, mapping, rows, text
from benchmark_live import PrerequisiteError, require_tool


class Generator:
    """Own one foreground worker and its request/response evidence."""

    def __init__(self, config: JsonMap, directory: Path) -> None:
        self.config = config
        self.directory = directory
        generator = mapping(config["generator"])
        command = [text(part) for part in rows(generator["argv"])]
        command[0] = require_tool(command[0])
        if Path(command[0]).name == "ssh":
            known_hosts = Path(text(generator["known_hosts"])).expanduser().resolve()
            if not known_hosts.is_file():
                raise PrerequisiteError(f"missing_generator_known_hosts:{known_hosts}")
            options = [
                "BatchMode=yes", "StrictHostKeyChecking=yes",
                f"UserKnownHostsFile={json.dumps(str(known_hosts))}",
                "GlobalKnownHostsFile=/dev/null", "KnownHostsCommand=none",
                "VerifyHostKeyDNS=no", "UpdateHostKeys=no", "CheckHostIP=no",
                "ControlMaster=no", "ControlPath=none",
            ]
            command = [command[0], *[part for option in options for part in ("-o", option)], *command[1:]]
        self.log = (directory / "generator-stderr.log").open("xb")
        try:
            self.child = subprocess.Popen(
                command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=self.log, start_new_session=True,
            )
        except OSError:
            self.log.close()
            raise
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.child.stdout, selectors.EVENT_READ)
        self.exchanges: list[dict] = []
        self.provenance: JsonMap = {}
        self.cell: Path | None = None
        self.closed = False
        self.command_failed = False

    def __enter__(self) -> Generator:
        try:
            self.provenance = self.request("hello", {"config": self.config})
            expected = {
                path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                for path in (Path(__file__), Path(__file__).with_name("capacity_generator.py"),
                             Path(__file__).with_name("benchmark_live.py"),
                             Path(__file__).with_name("capacity_generator_processes.py"),
                             Path(__file__).with_name("capacity_live.py"))
            }
            if self.provenance["harness_sha256"] != expected:
                raise RuntimeError("generator_harness_revision_mismatch")
            if self.provenance["sender_sha"] != self.config["sender_sha"]:
                raise RuntimeError("generator_sender_source_mismatch")
            return self
        except (OSError, ValueError, KeyError, RuntimeError):
            self.__exit__()
            raise

    def request(self, operation: str, payload: JsonMap | None = None) -> JsonMap:
        started = time.monotonic()
        self.child.stdin.write((json.dumps({"operation": operation, **(payload or {})}) + "\n").encode())
        self.child.stdin.flush()
        # Control bounds do not enter the capacity evaluator or its sample windows.
        timeout = 30 + 15 * 200 if operation == "prepare" else 3600
        deadline = started + timeout
        line = bytearray()
        while b"\n" not in line:
            if not self.selector.select(max(0, deadline - time.monotonic())):
                raise RuntimeError(f"generator_control_timeout:{operation}")
            chunk = os.read(self.child.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError(f"generator_channel_closed:{operation}")
            line.extend(chunk)
        response = mapping(json.loads(line))
        self.exchanges.append({
            "operation": operation, "bench_sent": started,
            "bench_received": time.monotonic(), "response": response,
        })
        if "error" in response:
            self.command_failed = True
            message = text(response["error"])
            if response.get("prerequisite"):
                raise PrerequisiteError(message)
            raise RuntimeError(message)
        return response

    def prepare(self, directory: Path, cell: JsonMap) -> None:
        self.cell = directory
        result = self.request("prepare", {"label": directory.name, **cell})
        (directory / "generator.json").write_text(json.dumps(result, indent=2) + "\n")

    def retire(self, directory: Path, verdict: JsonMap) -> None:
        # Both hosts must retain the verdict and manifest before G deletes media.
        (directory / "verdict.json").write_text(json.dumps(verdict, indent=2) + "\n")
        result = self.request("manifest", {"verdict": verdict})
        (directory / "media-manifest.json").write_text(json.dumps(result["manifest"], indent=2) + "\n")
        (directory / "generator-logs.json").write_text(json.dumps(result["logs"], indent=2) + "\n")
        self.request("delete")
        self.cell = None

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        try:
            self.child.stdin.close()
            # EOF also interrupts an in-progress publisher-readiness wait on G.
            try:
                self.child.wait(timeout=5 * (3 * 200 + 2) + 30)
            except subprocess.TimeoutExpired:
                os.killpg(self.child.pid, signal.SIGKILL)
                self.child.wait(timeout=5)
                raise
            if self.child.returncode and not self.command_failed:
                raise RuntimeError(f"generator_exited:{self.child.returncode}")
        finally:
            self.selector.close()
            self.child.stdout.close()
            self.log.close()
            (self.directory / "generator-control.json").write_text(
                json.dumps({"provenance": self.provenance, "exchanges": self.exchanges}, indent=2) + "\n"
            )

    def __exit__(self, *_: tuple) -> None:
        self.close()

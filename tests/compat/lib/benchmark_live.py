"""Resource ownership and explicit prerequisite handling for real benchmarks."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
from contextlib import ExitStack
from pathlib import Path
from typing import IO

from benchmark_fixture_io import JsonMap, mapping, rows, text


class PrerequisiteError(RuntimeError):
    """A named prerequisite is unavailable, not a failed experiment."""


def require_tool(name: str) -> str:
    resolved = shutil.which(name)
    if resolved is None:
        raise PrerequisiteError(f"missing_executable:{name}")
    return str(Path(resolved).resolve())


def argv(value: dict, variables: dict[str, str | int]) -> list[str]:
    command = [text(part).format_map(variables) for part in rows(value["argv"])]
    command[0] = require_tool(command[0])
    return command


def port(value: int) -> int:
    if not 43000 <= value <= 43999:
        raise ValueError("benchmark TCP/UDP service ports must be in 43000..43999")
    return value


class Processes:
    """Contain every launched process group through success and failure."""

    def __init__(self) -> None:
        self.stack = ExitStack()
        self.children: list[subprocess.Popen] = []
        self.frames: dict[int, int] = {}
        self.bytes: dict[int, int] = {}
        self.readers: list[threading.Thread] = []
        self.closed = False

    def __enter__(self) -> Processes:
        return self

    def start(
        self, command: list[str], log: Path, marker: str | None = None,
        *, cwd: Path | None = None, env: dict[str, str] | None = None,
    ) -> subprocess.Popen:
        destination = self.stack.enter_context(log.open("xb"))
        ready = threading.Event()
        child = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True, cwd=cwd, env=env,
        )
        self.children.append(child)

        def consume(source: IO[bytes]) -> None:
            with source:
                for line in source:
                    destination.write(line)
                    destination.flush()
                    match = re.fullmatch(rb"frame=(\d+)\s*", line)
                    if match:
                        self.frames[child.pid] = int(match[1])
                    match = re.fullmatch(rb"total_size=(\d+)\s*", line)
                    if match:
                        self.bytes[child.pid] = int(match[1])
                    if marker is not None and marker.encode() in line:
                        ready.set()

        reader = threading.Thread(target=consume, args=(child.stdout,), daemon=True)
        reader.start()
        self.readers.append(reader)
        if marker is not None and not ready.wait(15):
            raise RuntimeError(f"readiness_timeout:{command[0]}: see {log}")
        return child

    def alive(self) -> None:
        for child in self.children:
            if child.poll() is not None:
                raise RuntimeError(f"process_exited:{child.args[0]}:{child.returncode}")

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        for child in reversed(self.children):
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        try:
            for child in reversed(self.children):
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=5)
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            for reader in self.readers:
                reader.join(timeout=5)
                if reader.is_alive():
                    raise RuntimeError("log_reader_survived_teardown")
        finally:
            self.stack.close()

    def __exit__(self, *_: tuple) -> None:
        self.close()


def write_verdict(path: Path, result: JsonMap) -> None:
    rendered = json.dumps(result, indent=2, sort_keys=True, allow_nan=False) + "\n"
    with path.open("x", encoding="utf-8") as destination:
        destination.write(rendered)
    print(rendered, end="")


def run_live(name: str, config_path: Path | None, output: Path | None, rule: str) -> int:
    if config_path is None:
        print(json.dumps({
            "scenario": name, "source": "live", "status": "SKIP", "qualified": False,
            "reason": "missing_live_config: --config is required",
        }))
        return 77
    try:
        if output is None:
            raise ValueError("real runs require --output")
        if output.exists():
            raise FileExistsError(f"refusing to replace {output}")
        config_bytes = config_path.read_bytes()
        config = mapping(json.loads(config_bytes))
        if config.get("schema_version") != 1:
            raise ValueError("real-run config requires schema_version 1")
        artifacts = output.resolve().with_name(output.stem + "-artifacts")
        artifacts.mkdir()
        if name == "relay-capacity-probe":
            from capacity_live import capture

            result = capture(config, artifacts)
        else:
            from sender_dns_live import campaign

            result = campaign(config, artifacts)
        result["rule_sha256"] = hashlib.sha256(rule.encode()).hexdigest()
        result["input_sha256"] = hashlib.sha256(config_bytes).hexdigest()
        result["artifacts"] = str(artifacts)
        write_verdict(output, result)
        if result.get("status") == "SKIP":
            return 77
        return 1 if result.get("winner") == "insufficient" else 0
    except PrerequisiteError as error:
        result = {
            "scenario": name, "source": "live", "status": "SKIP", "qualified": False,
            "reason": str(error),
        }
        if output is not None and not output.exists():
            write_verdict(output, result)
        else:
            print(json.dumps(result))
        return 77
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"{name}: {error}", file=sys.stderr)
        return 2

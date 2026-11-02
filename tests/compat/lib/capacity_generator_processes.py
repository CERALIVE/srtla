"""Generator-only teardown, including interrupted or previously closed owners."""

from __future__ import annotations

import os
import signal
import subprocess

from benchmark_live import Processes


def reap(processes: Processes) -> None:
    """Always finish the kill/reap sweep before releasing readers and logs."""
    failures = []
    try:
        for child in reversed(processes.children):
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        for child in reversed(processes.children):
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                # The unconditional sweep below kills every remaining group.
                continue
    finally:
        for child in reversed(processes.children):
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except OSError as error:
                failures.append(f"kill:{child.pid}:{error}")
        for child in reversed(processes.children):
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                failures.append(f"process:{child.pid}")
            except OSError as error:
                failures.append(f"wait:{child.pid}:{error}")
            try:
                os.killpg(child.pid, 0)
            except ProcessLookupError:
                pass
            except OSError as error:
                failures.append(f"group:{child.pid}:{error}")
            else:
                failures.append(f"group:{child.pid}")
        for reader in processes.readers:
            reader.join(timeout=5)
            if reader.is_alive():
                failures.append("log_reader")
        processes.stack.close()
        processes.closed = True
        if failures:
            raise RuntimeError("generator_teardown_incomplete:" + ",".join(failures))

"""Remote H1 regressions using real foreground worker subprocesses."""

from __future__ import annotations

import copy
import json
import os
import selectors
import shutil
import subprocess
import sys
import tempfile
import threading
from contextlib import contextmanager
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import capacity_live
import capacity_probe
from benchmark_live import Processes, run_live
from contextlib import redirect_stdout
from io import StringIO

LIB = Path(__file__).resolve().parent
PUBLISHER = (
    "import signal; "
    "print('out_time_us=N/A\\ntotal_size=N/A\\ntotal_size=0',flush=True); "
    "print('total_size=1316',flush=True); signal.pause()"
)
SINK = (
    "import pathlib,re,signal,sys; "
    "p=pathlib.Path(sys.argv[1]); "
    "assert re.search(r'^total_size=[1-9][0-9]*$',p.read_text(),re.M); "
    "pathlib.Path(sys.argv[2]).write_bytes(b'x'*188); "
    "print('SINK_READY',flush=True); signal.pause()"
)


def config_for(root: Path, *, simulated: bool = False, positive: bool = True) -> dict:
    launcher = (
        "import sys; sys.path.insert(0,sys.argv[1]); "
        "from capacity_remote_test_support import relay_main; relay_main(sys.argv[2])"
    )
    generator_root = root / "generator"
    generator_root.mkdir()
    publisher = PUBLISHER if positive else "import signal; print('total_size=0',flush=True); signal.pause()"
    command = [sys.executable, "-c", launcher, str(LIB), "simulated" if simulated else "real"]
    return {
        "schema_version": 1, "duration_s": 2, "samples": 3, "receiver_core": 0,
        "interface": "bench-uplink", "link_addresses": ["198.18.0.2"],
        "provider_class": "test:remote", "sender_ref": "main", "sender_sha": "1" * 40,
        "receiver": sys.executable,
        "sls": {"argv": [sys.executable, "-c", "import signal; signal.pause()"]},
        "sender": {"argv": [shutil.which("sleep"), "10000"]},
        "load": {"argv": [sys.executable, "-c", publisher], "ready": "out_time_us="},
        "sink": {"argv": [sys.executable, "-c", SINK, "{directory}/load-{bond}.log", "{media_file}"],
                 "ready": "SINK_READY"},
        "generator": {
            "argv": command,
            "directory": str(generator_root), "source_address": "198.18.0.2",
            "receiver_host": "198.18.0.1",
        },
        "preview": {}, "calibration": {},
    }


def worker_main(mode: str) -> None:
    """Replace only worker clocks/counter sources for exact window assertions."""
    import capacity_generator

    if mode == "teardown-error":
        original_reap = capacity_generator.reap

        def fail_teardown(owner):
            original_reap(owner)
            raise RuntimeError("injected_generator_teardown_failure")

        capacity_generator.reap = fail_teardown
    if mode == "iperf-fixture":
        original_tool = capacity_generator.require_tool
        original_start = Processes.start

        def tool(name):
            return sys.executable if name == "iperf3" else original_tool(name)

        def start(owner, command, log, marker=None, **options):
            if log.name == "iperf.log":
                command = [sys.executable, "-c",
                           "import signal;print('Server listening on fixture',flush=True);signal.pause()"]
            return original_start(owner, command, log, marker, **options)

        capacity_generator.require_tool = tool
        Processes.start = start
    if mode == "low-disk":
        capacity_live.shutil.disk_usage = lambda _: SimpleNamespace(free=0)
    if mode in ("simulated", "counter-reset"):
        original = capacity_generator.Worker.snapshot

        def snapshot(worker):
            index = getattr(worker, "test_snapshot_index", 0)
            worker.test_snapshot_index = index + 1
            for load in worker.loads:
                worker.processes.bytes[load.pid] = 1000000 + index * 750000
            if mode == "counter-reset" and index:
                worker.processes.bytes[worker.loads[0].pid] = 0
                worker.processes.bytes[worker.loads[1].pid] = 10000000
            for path in worker.outputs:
                with path.open("r+b") as destination:
                    destination.truncate(1000000 + index * 750000)
            result = original(worker)
            result["monotonic_s"] = 100 + index
            return result

        capacity_generator.Worker.snapshot = snapshot
    capacity_generator.main()


def relay_main(mode: str) -> None:
    """A killable local SSH stand-in; EOF must reach the separate worker."""
    command = [
        sys.executable, "-c",
        "import sys;sys.path.insert(0,sys.argv[1]);from capacity_remote_test_support import worker_main;worker_main(sys.argv[2])",
        str(LIB), mode,
    ]
    if os.environ.get("H1_TEST_NETNS") == "1":
        command = ["unshare", "--net", *command]
    with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE) as child:
        def forward() -> None:
            try:
                for line in sys.stdin.buffer:
                    child.stdin.write(line)
                    child.stdin.flush()
            except BrokenPipeError:
                return
            finally:
                child.stdin.close()

        threading.Thread(target=forward, daemon=True).start()
        for line in child.stdout:
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()
        raise SystemExit(child.wait(timeout=10))


@contextmanager
def peer(root: Path, config: dict):
    from capacity_remote import Generator

    bench = root / "bench"
    bench.mkdir()
    with Generator(config, bench) as generator:
        yield generator, bench


def exited(pids: list[int]) -> None:
    """Subscribe before EOF/termination; pidfds provide exact exit events."""
    with selectors.DefaultSelector() as selector:
        descriptors = []
        try:
            for pid in pids:
                try:
                    descriptor = os.pidfd_open(pid)
                except ProcessLookupError:
                    continue
                descriptors.append(descriptor)
                selector.register(descriptor, selectors.EVENT_READ)
            while selector.get_map():
                events = selector.select(10)
                if not events:
                    raise AssertionError("owned_generator_process_survived_teardown")
                for key, _ in events:
                    selector.unregister(key.fileobj)
        finally:
            for descriptor in descriptors:
                os.close(descriptor)


def bench_capture(root: Path, config: dict, generator, *, metric_updates=None) -> tuple[dict, list[str]]:
    """Keep capture assembly intact; fake the bench OS boundary, not the worker."""
    roles = []
    cpu = [[0, 0, 0, 100, 0, 0, 0, 0]]
    metric = {
        "srtla_groups": 1, "srtla_groups_established": 1, "srtla_connections": 16,
        "srtla_auth_failures_total": 0,
        **{f'srtla_groups_removed_total{{reason="{reason}"}}': 0
           for reason in ("evicted", "idle_timeout", "srt_error", "auth_failed")},
    }
    metric.update(metric_updates or {})
    original_read, original_iterdir = Path.read_text, Path.iterdir

    def read_status(path, *args, **kwargs):
        return "VmRSS:\t42 kB\n" if path == Path("/proc/202/status") else original_read(path, *args, **kwargs)

    def read_fds(path):
        return iter([Path("fd0")]) if path == Path("/proc/202/fd") else original_iterdir(path)

    def start(command, log, *args, **kwargs):
        roles.append(log.stem)
        return SimpleNamespace(pid=202 if log.stem == "receiver" else 101)

    with patch("capacity_live.Processes") as factory, \
            patch("capacity_live.require_tool", side_effect=lambda value: value), \
            patch("capacity_live.cpu_counters", side_effect=[cpu, cpu, [[10, 0, 0, 190, 0, 0, 0, 0]], [[20, 0, 0, 280, 0, 0, 0, 0]]]), \
            patch("capacity_live.nic_counters", side_effect=[[0]*4, [0]*4, [1000000, 1000000, 1000, 1000], [2000000, 2000000, 2000, 2000]]), \
            patch("capacity_live.process_ticks", return_value=0), \
            patch("capacity_live.metrics", side_effect=[
                {**metric, "srtla_packets_received_total": packets, "srtla_recv_batches_total": batches}
                for packets, batches in ((0, 0), (0, 0), (1000, 100), (2000, 200))
            ]), \
            patch("capacity_live.udp_errors", return_value=0), \
            patch("capacity_live.time.monotonic", side_effect=lambda: next(clock)), \
            patch("capacity_live.threading.Event.wait", return_value=True), \
            patch.object(Path, "read_text", read_status), patch.object(Path, "iterdir", read_fds):
        # The client uses the same time module; keep control clocks independent.
        import capacity_remote
        clock = iter([0, 0, 1, 1, 2, 2, 2])
        with patch.object(capacity_remote, "time", SimpleNamespace(monotonic=lambda: 42)):
            owner = factory.return_value.__enter__.return_value
            owner.start.side_effect = start
            cell = capacity_live.measure(config, root / "cell", 1, 6, 16, generator=generator)
    return cell, roles



def paired_capture_results() -> list[dict]:
    """Capture the same synthetic matrix through both real control boundaries."""
    from test_benchmark_harnesses import capacity_fixture

    fixture = capacity_fixture()
    with tempfile.TemporaryDirectory() as name:
        root = Path(name)
        remote_config = config_for(root)
        remote_config.update(bonds=[25], duration_s=1800)
        local_config = {key: value for key, value in remote_config.items() if key != "generator"}
        remote_owner = None

        def collect(config, directory, bonds, bitrate, links, *, generator=None):
            nonlocal remote_owner
            directory.mkdir()
            if generator is None:
                (directory / "delivered-0.ts").write_bytes(b"media")
            else:
                remote_owner = generator
                generator.prepare(directory, {"bonds": 1, "bitrate": 6, "links": 1})
                generator.request("start")
                generator.request("finish")
            cell = copy.deepcopy(next(
                cell for cell in fixture["cells"]
                if cell["bitrate_mbps"] == bitrate and cell["links"] == links
            ))
            cell.update(receiver_cpu_pct=10, offered_goodput_mbps=bonds * bitrate)
            return cell

        def preview(config, directory):
            if "generator" in config:
                assert remote_owner.child.poll() == 0
            return fixture["preview_trials"]

        results = []
        for mode, config in (("local", local_config), ("remote", remote_config)):
            source, output = root / f"{mode}.json", root / f"{mode}-verdict.json"
            source.write_text(json.dumps(config))
            with patch("capacity_live.calibrate", return_value=(
                fixture["sustainable_nic_mbps"], fixture["sustainable_pps"], [],
            )), patch("capacity_live.measure", side_effect=collect), \
                    patch("capacity_live.preview_trials", side_effect=preview), \
                    redirect_stdout(StringIO()):
                assert run_live("relay-capacity-probe", source, output, capacity_probe.RULE) == 0
            results.append(json.loads(output.read_text()))
    return results

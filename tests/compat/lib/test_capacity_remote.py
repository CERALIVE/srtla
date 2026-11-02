"""Remote H1 behavior regressions; shared with both harness selftests."""

from __future__ import annotations

import copy
import hashlib
import json
import os
import selectors
import signal
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import capacity_live
import capacity_probe
from benchmark_live import Processes, PrerequisiteError
from capacity_remote_test_support import bench_capture, config_for, exited, paired_capture_results, peer
from test_capacity_remote_review import RemoteReviewTests
from test_capacity_remote_teardown import TeardownTests

class RemoteGeneratorTests(RemoteReviewTests, TeardownTests):
    def test_remote_generator_runs_no_load_sender_or_sink_on_bench(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            config = config_for(root, simulated=True)
            with peer(root, config) as (generator, bench):
                cell, roles = bench_capture(bench, config, generator)
                self.assertEqual(roles, ["sls", "receiver"])
                self.assertEqual(cell["per_core_cpu_pct"], [10])
                self.assertEqual((cell["nic_in_mbps"], cell["pps_in"]), (8, 1000))
                self.assertFalse(list(bench.rglob("delivered-*.ts")))
                remote = json.loads((bench / "cell/generator.json").read_text())
                self.assertEqual(len(remote["pids"]), 3)
                self.assertEqual(Path(remote["directory"], "ips.txt").read_text().splitlines(), ["198.18.0.2"] * 16)

    def test_remote_goodput_uses_generator_counters_and_its_recorded_window(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            config = config_for(root, simulated=True)
            with peer(root, config) as (generator, bench):
                cell, _ = bench_capture(bench, config, generator)
                window = json.loads((bench / "cell/generator-window.json").read_text())
                self.assertEqual((window["begin"]["offered_bytes"], window["end"]["offered_bytes"]), (1000000, 4000000))
                self.assertEqual((window["elapsed_s"], cell["duration_s"]), (4, 2))
                self.assertEqual((cell["offered_goodput_mbps"], cell["delivered_goodput_mbps"]), (6, 6))
                self.assertEqual(window["bench_end"] - window["bench_start"], 2)
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            config = config_for(root)
            config["generator"]["argv"][-1] = "counter-reset"
            with peer(root, config) as (generator, bench):
                cell = bench / "cell"
                cell.mkdir()
                generator.prepare(cell, {"bonds": 2, "bitrate": 6, "links": 1})
                generator.request("start")
                with self.assertRaisesRegex(RuntimeError, "^generator_counter_reset$"):
                    generator.request("alive")

    def test_remote_publisher_progress_gates_remote_sink_and_timeout_cleans_both_hosts(self) -> None:
        for positive in (True, False):
            with self.subTest(positive=positive), tempfile.TemporaryDirectory() as name:
                root = Path(name)
                config = config_for(root, positive=positive)
                pids = []
                bench_children = []
                with peer(root, config) as (generator, bench):
                    directory = bench / "cell"
                    directory.mkdir()
                    if positive:
                        generator.prepare(directory, {"bonds": 1, "bitrate": 6, "links": 1})
                        record = json.loads((directory / "generator.json").read_text())
                        pids = record["pids"]
                        self.assertEqual(Path(record["directory"], "sink-0.log").read_text().strip(), "SINK_READY")
                    else:
                        original_start = Processes.start

                        def launch(owner, command, log, marker=None, **options):
                            if log.name == "receiver.log":
                                command = [sys.executable, "-c",
                                           "import signal;print('srtla_rec is now running',flush=True);signal.pause()"]
                            child = original_start(owner, command, log, marker, **options)
                            bench_children.append(child)
                            return child

                        with patch.object(Processes, "start", launch), \
                                self.assertRaisesRegex(RuntimeError, "^publisher_progress_not_ready:"):
                            capacity_live.measure(config, bench / "failed-cell", 1, 6, 1, generator=generator)
                        pids = generator.exchanges[-1]["response"]["owned_pids"]
                        self.assertEqual(len(bench_children), 2)
                        self.assertTrue(all(child.poll() is not None for child in bench_children))
                        self.assertFalse(list((root / "generator").rglob("sink-0.log")))
                exited(pids)

    def test_remote_calibration_peer_is_owned_and_stopped_before_media(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            config = config_for(root)
            config["calibration"] = {"host": "198.18.0.2", "port": 43000, "offered_mbps": [100, 500, 1000]}
            config["generator"]["argv"][-1] = "iperf-fixture"
            with peer(root, config) as (generator, bench):
                record = generator.request("iperf")
                self.assertGreater(record["controller_lease_s"], 2 * 3 * (30 + 30))
                with os.fdopen(os.pidfd_open(record["pid"]), "rb") as descriptor, \
                        selectors.DefaultSelector() as selector:
                    selector.register(descriptor, selectors.EVENT_READ)
                    generator.request("stop")
                    self.assertTrue(selector.select(10), "iperf peer survived stop")
                cell = bench / "cell"
                cell.mkdir()
                generator.prepare(cell, {"bonds": 1, "bitrate": 6, "links": 1})
                self.assertEqual(len(json.loads((cell / "generator.json").read_text())["pids"]), 3)

    def test_remote_media_manifest_precedes_delete_and_failure_retains_generator_media(self) -> None:
        for failure in (None, "verdict.json", "media-manifest.json",
                        "remote:verdict.json", "remote:media-manifest.json"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as name:
                root = Path(name)
                config = config_for(root)
                with peer(root, config) as (generator, bench):
                    cell = bench / "cell"
                    cell.mkdir()
                    generator.prepare(cell, {"bonds": 1, "bitrate": 6, "links": 1})
                    generator.request("start")
                    generator.request("finish")
                    remote = Path(json.loads((cell / "generator.json").read_text())["directory"])
                    media = remote / "delivered-0.ts"
                    payload = media.read_bytes()
                    if failure and failure.startswith("remote:"):
                        (remote / failure.removeprefix("remote:")).mkdir()
                    original = Path.write_text

                    def write(path, *args, **kwargs):
                        if path.name == failure:
                            raise OSError("retirement_write_failed")
                        return original(path, *args, **kwargs)

                    with patch.object(Path, "write_text", write):
                        if failure:
                            expected = RuntimeError if failure.startswith("remote:") else OSError
                            message = "Is a directory" if failure.startswith("remote:") else "^retirement_write_failed$"
                            with self.assertRaisesRegex(expected, message):
                                generator.retire(cell, {"completed": True})
                            self.assertEqual(media.read_bytes(), payload)
                        else:
                            generator.retire(cell, {"completed": True})
                            self.assertEqual(json.loads((cell / "media-manifest.json").read_text()), [{
                                "path": str(media), "size_bytes": 188,
                                "sha256": hashlib.sha256(payload).hexdigest(), "ffprobe": None,
                            }])
                            self.assertFalse(media.exists())
                            self.assertEqual(json.loads((remote / "verdict.json").read_text()), {"completed": True})

    def test_remote_channel_loss_stops_owned_generator_groups(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            config = config_for(root)
            with self.assertRaisesRegex(RuntimeError, "^generator_exited:-9$"), peer(root, config) as (generator, bench):
                cell = bench / "cell"
                cell.mkdir()
                generator.prepare(cell, {"bonds": 2, "bitrate": 6, "links": 4})
                pids = json.loads((cell / "generator.json").read_text())["pids"]
                with selectors.DefaultSelector() as selector:
                    descriptors = [os.pidfd_open(pid) for pid in pids]
                    try:
                        for descriptor in descriptors:
                            selector.register(descriptor, selectors.EVENT_READ)
                        os.kill(generator.child.pid, signal.SIGKILL)
                        while selector.get_map():
                            events = selector.select(10)
                            self.assertTrue(events, "generator child survived controller EOF")
                            for key, _ in events:
                                selector.unregister(key.fileobj)
                    finally:
                        for descriptor in descriptors:
                            os.close(descriptor)
                self.assertEqual(generator.child.wait(timeout=10), -signal.SIGKILL)

    def test_remote_sender_provenance_hashes_sender_not_transport(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            config = config_for(root)
            with peer(root, config) as (generator, _):
                expected = hashlib.sha256(Path(config["sender"]["argv"][0]).read_bytes()).hexdigest()
                transport = hashlib.sha256(Path(sys.executable).read_bytes()).hexdigest()
                self.assertEqual(generator.provenance["sender_binary_sha256"], expected)
                self.assertNotEqual(expected, transport)
                self.assertEqual(generator.provenance["sender_sha"], "1" * 40)

    def test_local_and_remote_capture_apply_identical_h1_verdicts(self) -> None:
        from test_benchmark_harnesses import capacity_fixture

        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            config = config_for(root, simulated=True)
            with peer(root, config) as (generator, bench):
                measured, _ = bench_capture(bench, config, generator)
                document = capacity_fixture()
                document["source"] = "real-host"
                for cell in document["cells"]:
                    cell.update(receiver_cpu_pct=10, offered_goodput_mbps=cell["bonds"] * cell["bitrate_mbps"])
                for field, value, check in (
                    ("per_core_cpu_pct", [70, 10], "cpu"),
                    ("nic_in_mbps", 301, "nic"), ("nic_out_mbps", 301, "nic"),
                    ("pps_in", 60001, "pps"), ("pps_out", 60001, "pps"),
                    ("delivered_goodput_mbps", 94.9, "goodput"),
                ):
                    local, remote = copy.deepcopy(document), copy.deepcopy(document)
                    local["cells"][0][field] = remote["cells"][0][field] = value
                    remote["cells"][0]["per_core_cpu_pct"] = (
                        value if field == "per_core_cpu_pct" else measured["per_core_cpu_pct"]
                    )
                    a, b = capacity_probe.evaluate(local, captured=True), capacity_probe.evaluate(remote, captured=True)
                    self.assertEqual((a["softCapBonds"], b["softCapBonds"]), (0, 0))
                    self.assertFalse(b["cells"][0]["checks"][check])
                document["cells"].pop()
                self.assertEqual(capacity_probe.evaluate(document, captured=True)["softCapBonds"], 0)
        results = paired_capture_results()
        self.assertEqual(results[0]["rule_sha256"], results[1]["rule_sha256"])
        self.assertNotEqual(results[0]["input_sha256"], results[1]["input_sha256"])
        for result in results:
            result.pop("input_sha256")
            result.pop("artifacts")
        self.assertEqual(results[0], results[1])

    def test_remote_disk_reservation_uses_generator_filesystem(self) -> None:
        for missing in (True, False):
            with self.subTest(missing=missing), tempfile.TemporaryDirectory() as name:
                root = Path(name)
                config = config_for(root)
                if missing:
                    config["generator"]["directory"] = str(root / "missing-generator-disk")
                else:
                    config["generator"]["argv"][-1] = "low-disk"
                with peer(root, config) as (generator, bench):
                    cell = bench / "cell"
                    cell.mkdir()
                    error = RuntimeError if missing else PrerequisiteError
                    message = "missing-generator-disk" if missing else "^insufficient_h1_disk:free_bytes=0:required_bytes="
                    with self.assertRaisesRegex(error, message):
                        generator.prepare(cell, {"bonds": 1, "bitrate": 6, "links": 1})
                    self.assertFalse(list(bench.rglob("sender-*.log")))


class RemoteTests(RemoteGeneratorTests, unittest.TestCase):
    pass


if __name__ == "__main__":
    unittest.main()

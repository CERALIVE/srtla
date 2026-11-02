"""Discriminating failure paths for the four independently reviewed remote gates."""

from __future__ import annotations

import hashlib
import os
import shutil
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from benchmark_live import PrerequisiteError
from capacity_remote_review_support import matrix_capture
from capacity_remote_test_support import bench_capture, config_for, peer


class RemoteReviewTests:
    def test_worker_teardown_failure_is_reported_to_the_controller(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            config = config_for(root)
            config["generator"]["argv"][-1] = "teardown-error"
            with self.assertRaisesRegex(RuntimeError, "^generator_exited:1$"):
                with peer(root, config):
                    pass

    def test_remote_capture_rejects_each_mismatched_registration_gauge(self) -> None:
        for gauge, value in (("srtla_groups", 0), ("srtla_groups_established", 0), ("srtla_connections", 15)):
            with self.subTest(gauge=gauge), tempfile.TemporaryDirectory() as name:
                root = Path(name)
                config = config_for(root, simulated=True)
                with peer(root, config) as (generator, bench):
                    with self.assertRaisesRegex(RuntimeError, "^generator_registered_link_count_mismatch$"):
                        bench_capture(bench, config, generator, metric_updates={gauge: value})

    def test_remote_capture_starts_calibration_peer_and_stops_it_before_media(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            config = config_for(root)
            config.update(bonds=[25], duration_s=1800)
            config["generator"].update(calibration_peer=True)
            config["generator"]["argv"][-1] = "iperf-fixture"
            config["calibration"] = {"host": "198.18.0.2", "port": 43000, "offered_mbps": [100, 500, 1000]}
            _, observed = matrix_capture(root, config)
            self.assertEqual(observed, {"peer_alive_at_calibration": True, "peer_exited_before_media": True})

    def test_remote_capture_result_hashes_the_actual_generator_sender(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            config = config_for(root)
            config.update(bonds=[25], duration_s=1800)
            local_bin, remote_bin = root / "local-bin", root / "remote-bin"
            local_bin.mkdir()
            remote_bin.mkdir()
            sender = Path(shutil.which("sleep"))
            (local_bin / "h1-sender-fixture").symlink_to(sys.executable)
            (remote_bin / "h1-sender-fixture").symlink_to(sender)
            config["sender"]["argv"][0] = "h1-sender-fixture"
            config["generator"]["argv"] = [
                shutil.which("env"), f"PATH={remote_bin}:{os.environ['PATH']}",
                *config["generator"]["argv"],
            ]
            with patch.dict(os.environ, {"PATH": f"{local_bin}:{os.environ['PATH']}"}):
                result, _ = matrix_capture(root, config)
            expected = hashlib.sha256(sender.read_bytes()).hexdigest()
            self.assertNotEqual(expected, hashlib.sha256(Path(sys.executable).read_bytes()).hexdigest())
            self.assertEqual(result["sender_binary_sha256"], expected)

    def test_remote_capture_requires_the_bench_evidence_disk_reserve(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            config = config_for(root, simulated=True)
            with peer(root, config) as (generator, bench):
                with patch("capacity_live.shutil.disk_usage", return_value=SimpleNamespace(free=1024**3 - 1)), \
                        self.assertRaisesRegex(PrerequisiteError, "^insufficient_h1_evidence_disk$"):
                    bench_capture(bench, config, generator)
                self.assertFalse((bench / "cell").exists())

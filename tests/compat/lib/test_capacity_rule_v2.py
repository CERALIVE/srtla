"""Versioned H1 RSS windows, capture configuration and verdict provenance."""

from __future__ import annotations

import copy
import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import patch

from benchmark_fixture_io import JsonMap
from benchmark_live import run_live
import capacity_probe
from test_benchmark_harnesses import SCENARIOS, capacity_fixture


def v2_fixture() -> JsonMap:
    document = capacity_fixture()
    document["rule"] = "v2"
    for cell in document["cells"]:
        cell.update(
            duration_s=2400,
            packets_received=list(range(0, 4100, 100)),
            recv_batches=list(range(0, 410, 10)),
            udp_receive_errors=[0] * 41,
            rss_bytes=[1000] * 5 + [1200] * 36,
            stock_rss_bytes=[1000] * 41,
            fd_count=[20] * 41,
        )
    return document


class CapacityRuleV2Tests(unittest.TestCase):
    def test_step_inside_warmup_then_flat_passes(self) -> None:
        result = capacity_probe.evaluate(v2_fixture())
        self.assertEqual(result["softCapBonds"], 25)
        self.assertEqual(result["maxAssignedRelays"], 50)
        self.assertTrue(all(cell["checks"]["rss"] for cell in result["cells"]))

    def test_growth_at_or_after_warmup_fails(self) -> None:
        for index in (11, 40):
            fixture = v2_fixture()
            fixture["cells"][0]["rss_bytes"][index:] = [1400] * (41 - index)
            with self.subTest(index=index):
                result = capacity_probe.evaluate(fixture)
                self.assertEqual(result["softCapBonds"], 0)
                self.assertFalse(result["cells"][0]["checks"]["rss"])
                self.assertEqual(result["cells"][0]["rss_window"]["reason"], "monotonic_growth_exceeds_stock")

    def test_stock_growth_is_compared_only_over_same_post_warmup_window(self) -> None:
        for stock, expected in (
            ([1000] * 20 + [1200] * 21, True),
            ([1000] * 20 + [1400] * 21, True),
            ([1000] * 5 + [1400] * 36, False),
        ):
            fixture = v2_fixture()
            fixture["cells"][0].update(
                rss_bytes=[1000] * 20 + [1200] * 21, stock_rss_bytes=stock,
            )
            with self.subTest(stock=stock):
                self.assertEqual(capacity_probe.evaluate(fixture)["cells"][0]["checks"]["rss"], expected)

    def test_short_post_warmup_window_has_named_failure(self) -> None:
        for duration, warmup in ((1800, 600), (2399, 600), (2400, 2401)):
            fixture = v2_fixture()
            fixture["warmup_s"] = warmup
            fixture["cells"][0]["duration_s"] = duration
            with self.subTest(duration=duration, warmup=warmup):
                result = capacity_probe.evaluate(fixture)
                self.assertEqual(result["softCapBonds"], 0)
                self.assertTrue(result["cells"][0]["checks"]["window"])
                self.assertEqual(result["cells"][0]["rss_window"]["reason"], "post_warmup_window_too_short")

    def test_first_sample_at_or_after_custom_warmup_starts_window(self) -> None:
        for warmup, expected, first in ((600, True, 600), (601, False, 660), (0, False, 0)):
            fixture = v2_fixture()
            fixture["warmup_s"] = warmup
            with self.subTest(warmup=warmup):
                cell = capacity_probe.evaluate(fixture)["cells"][0]
                self.assertEqual(cell["checks"]["rss"], expected)
                self.assertEqual(cell["rss_window"]["start_s"], first)

    def test_nonmonotonic_post_warmup_rss_keeps_v1_predicate(self) -> None:
        fixture = v2_fixture()
        fixture["cells"][0]["rss_bytes"][20:] = [1400] * 20 + [1300]
        self.assertTrue(capacity_probe.evaluate(fixture)["cells"][0]["checks"]["rss"])

    def test_same_input_changes_only_rss_checks_between_versions(self) -> None:
        fixture = v2_fixture()
        v2 = capacity_probe.evaluate(fixture)
        fixture["rule"] = "v1"
        v1 = capacity_probe.evaluate(fixture)
        self.assertEqual((v1["softCapBonds"], v2["softCapBonds"]), (0, 25))
        for before, after in zip(v1["cells"], v2["cells"]):
            self.assertEqual(before["checks"], {**after["checks"], "rss": False})
            self.assertFalse(before["checks"]["rss"])
            self.assertTrue(after["checks"]["rss"])
            self.assertEqual(before["metrics"], after["metrics"])
            self.assertEqual(before["recvmmsg_fill"], after["recvmmsg_fill"])
        self.assertEqual(v1["preview_transcode_max"], v2["preview_transcode_max"])

    def test_other_faults_still_remove_v2_capacity(self) -> None:
        for field, value, check in (
            ("per_core_cpu_pct", [70, 20], "cpu"),
            ("nic_out_mbps", 301, "nic"), ("pps_in", 60001, "pps"),
            ("udp_receive_errors", [0] * 40 + [1], "udp"),
            ("delivered_goodput_mbps", 94.9, "goodput"),
            ("auth_failures", 1, "auth"), ("evictions", 1, "evictions"),
            ("disconnects", 1, "disconnects"),
        ):
            fixture = v2_fixture()
            fixture["cells"][0][field] = value
            with self.subTest(field=field):
                result = capacity_probe.evaluate(fixture)
                self.assertEqual(result["softCapBonds"], 0)
                self.assertFalse(result["cells"][0]["checks"][check])
                self.assertTrue(result["cells"][0]["checks"]["rss"])

    def test_capture_config_extends_duration_and_keeps_sixty_second_samples(self) -> None:
        for overrides, duration, samples in (
            ({}, 2400, 41), ({"duration_s": 60, "samples": 3}, 2400, 41),
            ({"warmup_s": 601}, 2460, 42), ({"duration_s": 3001}, 3060, 52),
        ):
            config = {"rule": "v2", **overrides}
            before = copy.deepcopy(config)
            with self.subTest(overrides=overrides):
                measured = capacity_probe.measurement_config(config)
                self.assertEqual((measured["duration_s"], measured["samples"]), (duration, samples))
                self.assertEqual(config, before)

    def test_default_v1_capture_config_is_unchanged(self) -> None:
        config = {"duration_s": 2, "samples": 3}
        self.assertEqual(capacity_probe.measurement_config(config), config)

    def test_unknown_rule_and_invalid_v2_warmup_are_rejected(self) -> None:
        for overrides in ({"rule": "v3"}, {"warmup_s": -1}, {"warmup_s": float("nan")}):
            fixture = v2_fixture()
            fixture.update(overrides)
            with self.subTest(overrides=overrides), self.assertRaises(ValueError):
                capacity_probe.evaluate(fixture)

    def test_fixture_cli_records_selected_rule_hash_and_version(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, output = root / "fixture.json", root / "verdict.json"
            source.write_text(json.dumps(v2_fixture()))
            completed = subprocess.run(
                ["bash", str(SCENARIOS / "capacity-probe.sh"), "--fixture", str(source), "--output", str(output)],
                capture_output=True, text=True, timeout=10, check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            verdict = json.loads(output.read_text())
            self.assertEqual(verdict["rule_version"], "v2")
            self.assertEqual(verdict["rule_sha256"], hashlib.sha256(capacity_probe.RULE_V2.encode()).hexdigest())
            self.assertNotEqual(verdict["rule_sha256"], hashlib.sha256(capacity_probe.RULE.encode()).hexdigest())
            self.assertEqual(verdict["input_sha256"], hashlib.sha256(source.read_bytes()).hexdigest())

    def test_real_config_propagates_rule_duration_and_provenance(self) -> None:
        fixture = v2_fixture()
        config = {
            "schema_version": 1, "rule": "v2", "duration_s": 1800, "samples": 31,
            "sender_ref": "main", "sender_sha": "a" * 40,
            "provider_class": "fixture:relay", "receiver": sys.executable,
            "interface": "lo", "sender": {"argv": [sys.executable]},
            "sls": {}, "sink": {}, "load": {}, "preview": {}, "calibration": {},
            "link_addresses": ["127.0.0.1"], "bonds": [25],
        }

        def collect(settings, directory, bonds, bitrate, links):
            directory.mkdir()
            cell = copy.deepcopy(next(
                row for row in fixture["cells"] if (row["bitrate_mbps"], row["links"]) == (bitrate, links)
            ))
            cell.update(duration_s=settings["duration_s"], receiver_cpu_pct=10,
                        offered_goodput_mbps=bonds * bitrate)
            return cell

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, output = root / "config.json", root / "verdict.json"
            source.write_text(json.dumps(config))
            with patch("capacity_live.calibrate", return_value=(
                fixture["sustainable_nic_mbps"], fixture["sustainable_pps"], [],
            )), patch("capacity_live.measure", side_effect=collect), \
                    patch("capacity_live.preview_trials", return_value=fixture["preview_trials"]), \
                    redirect_stdout(StringIO()):
                status = run_live("relay-capacity-probe", source, output, capacity_probe.RULE)
            self.assertEqual(status, 0)
            verdict = json.loads(output.read_text())
            measured = json.loads((root / "verdict-artifacts/measurements.json").read_text())
            self.assertEqual(measured["rule"], "v2")
            self.assertEqual({cell["duration_s"] for cell in measured["cells"]}, {2400})
            self.assertEqual(verdict["rule_version"], "v2")
            self.assertEqual(verdict["rule_sha256"], hashlib.sha256(capacity_probe.RULE_V2.encode()).hexdigest())
            self.assertEqual(verdict["input_sha256"], hashlib.sha256(source.read_bytes()).hexdigest())
            self.assertEqual(verdict["softCapBonds"], 25)


if __name__ == "__main__":
    unittest.main()

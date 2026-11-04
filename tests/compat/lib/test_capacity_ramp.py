"""Synthetic v3 schedule, quality boundaries, live control timeout and provenance."""

from __future__ import annotations

import copy
import hashlib
import json
import signal
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import capacity_probe
import capacity_ramp as ramp
import capacity_ramp_live as live
from capacity_remote_test_support import config_for, exited
from test_benchmark_harnesses import capacity_fixture
from test_capacity_rule_v2 import v2_fixture

PROFILE = {"bitrate_mbps": 6, "links": 2}
LIB = Path(__file__).resolve().parent


def config() -> dict:
    return {
        "schema_version": 1, "source": "fixture", "rule": "v3", "mode": "ramp",
        "provider_class": "fixture:small", "sender_ref": "main", "receiver": "stock",
        "profiles": [PROFILE], "max_bonds": 20, "step_s": 20,
    }


def cell(count: int, profile: dict, duration: int, label: str) -> dict:
    return {
        "bonds": count, **profile, "duration_s": duration, "label": label,
        "offered_goodput_mbps": count * profile["bitrate_mbps"],
        "delivered_goodput_mbps": count * profile["bitrate_mbps"] * 0.98,
        "publisher_failures": 0, "disconnects": 0,
        "samples": [{
            "elapsed_s": index * 10, "per_core_cpu_pct": [95 if index == 1 else 20, 30],
            "rss_bytes": 1000 if index < 60 else 2000,
            "srt_drop_packets": 10, "srt_loss_packets": 20,
            "udp_rcvbuf_errors": 5, "udp_sndbuf_errors": 6,
            "nic": [index * 10000000, index * 20000000, index * 1000, index * 2000],
        } for index in range(duration // 10 + 1)],
    }


def fixture(*, failed_confirmation: bool = False, lower_bound: bool = False) -> dict:
    document = config()
    cells = [cell(n, PROFILE, 20, f"ramp-6-2-{n}") for n in (5, 10, 15, 20)]
    if not lower_bound:
        cells[-1]["delivered_goodput_mbps"] = 0
    count = 16 if lower_bound else 12
    for attempt in range(1, 3 if failed_confirmation else 2):
        prefix = f"confirm-6-2-{count}-{attempt}"
        cells.extend([
            cell(count, PROFILE, 2410, prefix + "-stock"),
            cell(count, PROFILE, 2410, prefix),
        ])
        if failed_confirmation and attempt == 1:
            cells[-1]["samples"][-1]["rss_bytes"] = 3000
        count -= 5
    return {**document, "cells": cells}


class RampTests(unittest.TestCase):
    def test_default_profiles_and_sampling_preserve_the_requested_loads(self) -> None:
        defaults = config()
        del defaults["profiles"], defaults["step_s"], defaults["max_bonds"]
        options = ramp.settings(defaults)
        self.assertEqual(options["profiles"], [
            {"bitrate_mbps": 6, "links": 2}, {"bitrate_mbps": 6, "links": 4},
            {"bitrate_mbps": 10, "links": 4},
        ])
        self.assertEqual(
            [options[key] for key in ("start_bonds", "increment", "max_bonds", "step_s", "warmup_s", "confirmation_s")],
            [5, 5, 200, 300, 600, 1800],
        )

    def test_each_break_criterion_has_its_own_named_failure(self) -> None:
        limits = ramp.settings(config())["thresholds"]
        for field, value, reason in (
            ("delivered_goodput_mbps", 29.3999, "goodput"),
            ("offered_goodput_mbps", 28, "offered_load"),
            ("publisher_failures", 1, "publishers"),
            ("disconnects", 1, "disconnects"),
            ("srt_drop_packets", 11, "srt_drop_packets"),
            ("srt_loss_packets", 21, "srt_loss_packets"),
            ("udp_rcvbuf_errors", 6, "udp_rcvbuf_errors"),
            ("udp_sndbuf_errors", 7, "udp_sndbuf_errors"),
        ):
            measured = cell(5, PROFILE, 20, "test")
            if field in measured:
                measured[field] = value
            else:
                measured["samples"][-1][field] = value
            with self.subTest(reason=reason):
                result = ramp.judge(measured, limits, 20)
                self.assertFalse(result["pass"])
                self.assertIn(reason, result["reasons"])

    def test_cpu_must_saturate_the_same_core_for_more_than_half_intervals(self) -> None:
        limits = ramp.settings(config())["thresholds"]
        for cpu, passed in (([[95, 20], [20, 95]], True), ([[95, 20], [95, 20]], False),
                            ([[94.99, 20], [94.99, 20]], True)):
            measured = cell(5, PROFILE, 20, "cpu")
            for sample, values in zip(measured["samples"][1:], cpu):
                sample["per_core_cpu_pct"] = values
            with self.subTest(cpu=cpu):
                self.assertEqual(ramp.judge(measured, limits, 20)["checks"]["cpu"], passed)

    def test_recorded_srt_thresholds_allow_exact_delta_only(self) -> None:
        options = ramp.settings({**config(), "thresholds": {"srt_drop_packets": 2, "srt_loss_packets": 3}})
        measured = cell(5, PROFILE, 20, "thresholds")
        measured["samples"][-1].update(srt_drop_packets=12, srt_loss_packets=23)
        self.assertTrue(ramp.judge(measured, options["thresholds"], 20)["pass"])
        measured["samples"][-1]["srt_drop_packets"] = 13
        self.assertEqual(ramp.judge(measured, options["thresholds"], 20)["reasons"], ["srt_drop_packets"])

    def test_stalled_offered_load_cannot_pass_goodput(self) -> None:
        measured = cell(5, PROFILE, 20, "stalled")
        measured.update(offered_goodput_mbps=0, delivered_goodput_mbps=0)
        result = ramp.judge(measured, ramp.settings(config())["thresholds"], 20)
        self.assertEqual(result["reasons"], ["goodput", "offered_load"])

    def test_real_cli_dispatches_v3_and_names_missing_remote_generator(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            source, output = Path(name, "config.json"), Path(name, "verdict.json")
            source.write_text(json.dumps(config()))
            completed = subprocess.run(
                [sys.executable, str(LIB / "capacity_probe.py"), "--real-host", "--config",
                 str(source), "--output", str(output)], capture_output=True, text=True, timeout=10,
            )
            self.assertEqual(completed.returncode, 77, completed.stderr)
            self.assertEqual(json.loads(output.read_text())["reason"], "missing_h1_v3_config:generator")

    def test_ceiling_is_last_pass_and_confirmation_uses_eighty_percent(self) -> None:
        result = ramp.evaluate(fixture())
        profile = result["profiles"][0]
        self.assertEqual((profile["ceiling"], profile["ceiling_relation"], profile["confirmed_bonds"]), (15, "=", 12))
        self.assertEqual((result["softCapBonds"], result["maxAssignedRelays"]), (12, 24))
        self.assertEqual(result["sustainable_nic_mbps"], {"in": 8, "out": 16})
        self.assertEqual(result["sustainable_pps"], {"in": 100, "out": 200})
        self.assertEqual(profile["confirmation_attempts"][0]["rss_window"]["duration_s"], 1810)

    def test_unsaturated_maximum_is_only_a_lower_bound(self) -> None:
        result = ramp.evaluate(fixture(lower_bound=True))
        profile = result["profiles"][0]
        self.assertEqual((profile["ceiling"], profile["ceiling_relation"], profile["confirmed_bonds"]), (20, ">=", 16))

    def test_failed_rss_confirmation_steps_down_exactly_one_increment(self) -> None:
        profile = ramp.evaluate(fixture(failed_confirmation=True))["profiles"][0]
        self.assertEqual([a["bonds"] for a in profile["confirmation_attempts"]], [12, 7])
        self.assertEqual(profile["confirmation_attempts"][0]["rss_window"]["reason"], "monotonic_growth_exceeds_stock")
        self.assertEqual(profile["confirmed_bonds"], 7)

    def test_two_failed_confirmations_report_zero_without_third_try(self) -> None:
        document = fixture(failed_confirmation=True)
        document["cells"][-1]["disconnects"] = 1
        result = ramp.evaluate(document)
        self.assertEqual((result["softCapBonds"], result["maxAssignedRelays"]), (0, 0))
        self.assertEqual(len(result["profiles"][0]["confirmation_attempts"]), 2)

    def test_failed_stock_confirmation_is_not_used_as_rss_allowance(self) -> None:
        document = fixture()
        stock = document["cells"][-2]
        stock["disconnects"] = 1
        document["cells"].pop()
        document["cells"].extend([
            cell(7, PROFILE, 2410, "confirm-6-2-7-2-stock"),
            cell(7, PROFILE, 2410, "confirm-6-2-7-2"),
        ])
        profile = ramp.evaluate(document)["profiles"][0]
        self.assertEqual(profile["confirmed_bonds"], 7)
        self.assertNotIn("measured", profile["confirmation_attempts"][0])

    def test_minimum_confirmed_profile_bounds_the_global_capacity(self) -> None:
        first = fixture(lower_bound=True)
        second = fixture()
        for measured in second["cells"]:
            measured["links"] = 4
            measured["label"] = measured["label"].replace("-6-2-", "-6-4-")
        document = {**first, "profiles": [PROFILE, {"bitrate_mbps": 6, "links": 4}],
                    "cells": first["cells"] + second["cells"]}
        result = ramp.evaluate(document)
        self.assertEqual([p["confirmed_bonds"] for p in result["profiles"]], [16, 12])
        self.assertEqual((result["softCapBonds"], result["maxAssignedRelays"]), (12, 24))

    def test_first_step_failure_has_zero_ceiling_and_no_confirmation(self) -> None:
        document = fixture()
        document["cells"] = [{**document["cells"][0], "failure": "publisher_progress_not_ready"}]
        profile = ramp.evaluate(document)["profiles"][0]
        self.assertEqual((profile["ceiling"], profile["confirmed_bonds"], profile["confirmation_attempts"]), (0, 0, []))

    def test_rss_predicate_matches_v2_over_equivalent_retained_samples(self) -> None:
        for values in ([1000] * 31, [1000] * 20 + [2000] * 11, [1000] * 20 + [2000] * 10 + [1500]):
            document = v2_fixture()
            document["cells"][0]["rss_bytes"][10:] = values
            v2 = capacity_probe.evaluate(document)["cells"][0]["checks"]["rss"]
            measured = cell(5, PROFILE, 2400, "rss")
            stock = copy.deepcopy(measured)
            for target, source in ((measured, [1000] * 10 + values), (stock, [1000] * 41)):
                target["samples"] = [{"elapsed_s": i * 60, "rss_bytes": v} for i, v in enumerate(source)]
            self.assertEqual(ramp.rss_check(measured, stock, 600)["pass"], v2)

    def test_invalid_selection_schedule_and_missing_samples_are_rejected(self) -> None:
        for overrides in ({"mode": "matrix"}, {"rule": "v2"}, {"max_bonds": 19},
                          {"max_bonds": 201}, {"warmup_s": 599}, {"confirmation_s": 1790},
                          {"step_s": 21}, {"profiles": [PROFILE, PROFILE]}, {"thresholds": {"cpu": 99}}):
            with self.subTest(overrides=overrides), self.assertRaises(ValueError):
                ramp.settings({**config(), **overrides})
        for change in ("missing", "reset", "truncated"):
            measured = cell(5, PROFILE, 20, "invalid")
            if change == "missing":
                measured["samples"].pop()
            elif change == "reset":
                measured["samples"][-1]["srt_drop_packets"] = 0
            else:
                measured["samples"][-1]["elapsed_s"] = 19
            with self.subTest(change=change), self.assertRaises(ValueError):
                ramp.judge(measured, ramp.settings(config())["thresholds"], 20)

    def test_fixture_cli_selects_v3_and_keeps_v1_v2_rule_hashes(self) -> None:
        for document, version, digest in (
            (capacity_fixture(), None, "6619782873491c7a0581922f991a1c1aefa7ea2ce5f2d72abc23ca299f3700aa"),
            (v2_fixture(), "v2", "d3073a860e67c0f79e9e98d76e1485559e7530b31cc6e153afe388d20fe11def"),
            (fixture(), "v3", hashlib.sha256(ramp.RULE_V3.encode()).hexdigest()),
        ):
            with tempfile.TemporaryDirectory() as name:
                source, output = Path(name, "fixture.json"), Path(name, "verdict.json")
                source.write_text(json.dumps(document))
                completed = subprocess.run(
                    [sys.executable, str(LIB / "capacity_probe.py"), "--fixture", str(source), "--output", str(output)],
                    capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                result = json.loads(output.read_text())
                self.assertEqual(result.get("rule_version"), version)
                self.assertEqual(result["rule_sha256"], digest)
                self.assertFalse(result["qualified"])

    def test_step_timeout_reaps_local_and_remote_processes_and_records_failure(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            options = config_for(root)
            options["step_timeout_s"] = 2
            options["interface"] = "lo"
            options["srt_stats"] = {"argv": [sys.executable, "-c", "print('{}')"]}
            children = []
            original_start = live.RampProcesses.start

            def start(owner, command, log, marker=None, **kwargs):
                if log.name == "receiver.log":
                    command = [sys.executable, "-c",
                               "import signal;print('srtla_rec is now running',flush=True);signal.pause()"]
                child = original_start(owner, command, log, marker, **kwargs)
                children.append(child)
                return child

            # Block only the OS metrics boundary, after real publishers/sinks exist.
            with patch.object(live.RampProcesses, "start", start), \
                    patch("capacity_live.metrics", side_effect=lambda _: signal.pause()), redirect_stdout(StringIO()):
                result = live.collect_cell(options, root, 1, PROFILE, 20, "timeout")
            self.assertEqual(result["failure"], "step_timeout")
            self.assertTrue(all(child.poll() is not None for child in children))
            remote = json.loads((root / "timeout/capture/generator.json").read_text())
            exited(remote["pids"])
            self.assertEqual(json.loads((root / "timeout/cell.json").read_text())["failure"], "step_timeout")

    def test_stats_command_returns_measured_counters_and_rejects_missing_publishers(self) -> None:
        for count, valid in ((5, True), (4, False)):
            with tempfile.TemporaryDirectory() as name:
                observed = {"pkt_rcv_drop": 2, "pkt_rcv_loss": 3, "publishers": count, "disconnects": 1}
                code = f"print({json.dumps(json.dumps(observed))})".replace("{", "{{").replace("}", "}}")
                options = {"srt_stats": {"argv": [sys.executable, "-c", code]}}
                if valid:
                    self.assertEqual(live.srt_stats(options, Path(name), 5, 0), observed)
                else:
                    with self.assertRaisesRegex(RuntimeError, "^publisher_disconnected$"):
                        live.srt_stats(options, Path(name), 5, 0)

    def test_live_cell_keeps_raw_samples_and_retires_remote_media(self) -> None:
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            options = config_for(root, simulated=True)
            options["step_timeout_s"] = 30
            options["srt_stats"] = {"argv": [
                sys.executable, "-c",
                "import json;print(json.dumps(dict(pkt_rcv_drop=2,pkt_rcv_loss=3,publishers=1,disconnects=0)))",
            ]}
            original_start = live.RampProcesses.start

            def start(owner, command, log, marker=None, **kwargs):
                if log.name == "receiver.log":
                    command = [sys.executable, "-c",
                               "import signal;print('srtla_rec is now running',flush=True);signal.pause()"]
                return original_start(owner, command, log, marker, **kwargs)

            metrics = {
                "srtla_groups": 1, "srtla_groups_established": 1, "srtla_connections": 2,
                "srtla_auth_failures_total": 0,
                "srtla_packets_received_total": 1000, "srtla_recv_batches_total": 100,
                **{f'srtla_groups_removed_total{{reason="{r}"}}': 0
                   for r in ("evicted", "idle_timeout", "srt_error", "auth_failed")},
            }
            clock = iter([0, 0, 10, 10, 20, 20, 20])
            cpu = [[0, 0, 0, 100, 0, 0, 0, 0]]
            with patch.object(live.RampProcesses, "start", start), \
                    patch("capacity_live.time", SimpleNamespace(monotonic=lambda: next(clock))), \
                    patch("capacity_live.threading", SimpleNamespace(Event=lambda: SimpleNamespace(wait=lambda _: None))), \
                    patch("capacity_live.cpu_counters", side_effect=[cpu, cpu, [[10, 0, 0, 190, 0, 0, 0, 0]],
                                                                    [[20, 0, 0, 280, 0, 0, 0, 0]]]), \
                    patch("capacity_live.nic_counters", side_effect=[[0] * 4, [0] * 4,
                                                                   [10000000, 20000000, 1000, 2000],
                                                                   [20000000, 40000000, 2000, 4000]]), \
                    patch("capacity_live.metrics", return_value=metrics), redirect_stdout(StringIO()):
                measured = live.collect_cell(options, root, 1, PROFILE, 20, "captured")
            self.assertNotIn("failure", measured)
            self.assertEqual([s["elapsed_s"] for s in measured["samples"]], [0, 10, 20])
            self.assertEqual([s["per_core_cpu_pct"] for s in measured["samples"]], [[0], [10], [10]])
            self.assertEqual(measured["samples"][-1]["nic"], [20000000, 40000000, 2000, 4000])
            self.assertEqual(measured["samples"][-1]["srt_drop_packets"], 2)
            self.assertEqual(len((root / "captured/progress.jsonl").read_text().splitlines()), 3)
            remote = json.loads((root / "captured/capture/generator.json").read_text())
            self.assertFalse(list(Path(remote["directory"]).glob("delivered-*.ts")))
            exited(remote["pids"])


if __name__ == "__main__":
    unittest.main()

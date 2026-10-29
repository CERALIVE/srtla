#!/usr/bin/env python3
"""H1/G5 regression tests without provider resources or privileged namespaces."""

from __future__ import annotations

import copy
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
import struct
import sys
import socket
import shutil
import os
import selectors

import yaml

import capacity_probe
import sender_dns
import capacity_live
import sender_dns_live
from benchmark_live import Processes, PrerequisiteError, port
from unittest.mock import patch
from types import SimpleNamespace
from contextlib import redirect_stdout
from io import StringIO
from benchmark_live import run_live

SCENARIOS = Path(__file__).resolve().parent.parent / "scenarios"


def capacity_fixture() -> dict:
    cell = {
        "bonds": 25,
        "duration_s": 1800,
        "per_core_cpu_pct": [40, 20],
        "receiver_core": 0,
        "nic_in_mbps": 100,
        "nic_out_mbps": 100,
        "pps_in": 25000,
        "pps_out": 25000,
        "packets_received": [0, 100, 400],
        "recv_batches": [0, 10, 30],
        "udp_receive_errors": [0, 0, 0],
        "sls_cpu_pct": 30,
        "rss_bytes": [1000, 1100, 1000],
        "stock_rss_bytes": [1000, 1100, 1000],
        "fd_count": [20, 20, 20],
        "delivered_goodput_mbps": 100,
        "baseline_goodput_mbps": 100,
        "auth_failures": 0,
        "evictions": 0,
        "disconnects": 0,
    }
    return {
        "schema_version": 1,
        "source": "fixture",
        "provider_class": "fixture:relay",
        "sender_ref": "main",
        "receiver": "stock",
        "sustainable_nic_mbps": {"in": 500, "out": 500},
        "sustainable_pps": {"in": 100000, "out": 100000},
        "per_bond_pps_6mbps": 1000,
        "cells": [
            dict(copy.deepcopy(cell), bitrate_mbps=bitrate, links=links)
            for bitrate in (6, 10, 20)
            for links in (1, 4, 16)
        ],
        "preview_trials": [
            {"transcodes": 2, "duration_s": 1800, "cpu_pct": 60, "minimum_fps": 10},
            {"transcodes": 3, "duration_s": 1800, "cpu_pct": 70, "minimum_fps": 8},
        ],
    }


def dns_fixture() -> dict:
    observations = []
    for sender in sender_dns.SENDERS:
        for scenario in sender_dns.SCENARIOS:
            nodes = ["g1-eu", "g1-eu"]
            if scenario in ("control", "stale_cache", "dual_stack"):
                nodes[1] = "g2-mia"
            ipv6 = scenario == "aaaa_only"
            uplinks = []
            for index, node in enumerate(nodes):
                address = "192.0.2.1" if node == "g1-eu" else "192.0.2.2"
                if ipv6 or (scenario == "dual_stack" and index == 1):
                    address = "2001:db8::1" if node == "g1-eu" else "2001:db8::2"
                if scenario == "nat64" and index == 1:
                    address = "64:ff9b::c000:201"
                uplinks.append(
                    {
                        "namespace": f"uplink-{index}",
                        "resolver": f"resolver-{index}",
                        "address": address,
                        "cname_chain": [] if scenario == "control" else [node],
                    }
                )
            observations.append(
                {
                    "sender": sender,
                    "scenario": scenario,
                    "hostname": (
                        "geo.ingest.example.test"
                        if scenario == "control"
                        else "r-abcdefghij.ingest.example.test"
                    ),
                    "resolver_queries": ["resolver-0", "resolver-1"],
                    "uplinks": uplinks,
                }
            )
    return {
        "schema_version": 1,
        "source": "fixture",
        "nodes": {
            "g1-eu": {"a": "192.0.2.1", "aaaa": "2001:db8::1"},
            "g2-mia": {"a": "192.0.2.2", "aaaa": "2001:db8::2"},
        },
        "observations": observations,
    }


class CapacityTests(unittest.TestCase):
    def test_formula_uses_each_measured_limit_and_floors(self) -> None:
        for bonds, mbps, pps, expected in (
            (25, 500, 100000, 25),
            (200, 300, 100000, 30),
            (200, 500, 30000, 18),
            (200, 309, 100000, 30),
        ):
            with self.subTest(expected=expected):
                result = capacity_probe.capacity(bonds, mbps, pps, 1000)
                self.assertEqual(result, (expected, expected * 2))

    def test_complete_matrix_and_preview_cap_are_derived(self) -> None:
        result = capacity_probe.evaluate(capacity_fixture())
        self.assertEqual(result["softCapBonds"], 25)
        self.assertEqual(result["maxAssignedRelays"], 50)
        self.assertEqual(result["preview_transcode_max"], 2)
        self.assertEqual(result["qualified"], False)
        self.assertEqual(result["cpu_bound"], False)

    def test_preview_cpu_boundary_is_independent_of_fps(self) -> None:
        for cpu, expected in ((69.9, 3), (70, 2)):
            fixture = capacity_fixture()
            fixture["preview_trials"][1].update(cpu_pct=cpu, minimum_fps=10)
            with self.subTest(cpu=cpu):
                self.assertEqual(capacity_probe.evaluate(fixture)["preview_transcode_max"], expected)

    def test_missing_matrix_cell_cannot_size_a_provider(self) -> None:
        fixture = capacity_fixture()
        fixture["cells"].pop()
        result = capacity_probe.evaluate(fixture)
        self.assertEqual(result["softCapBonds"], 0)
        self.assertEqual(result["winner"], "insufficient")

    def test_cpu_and_headroom_gate_is_not_a_nic_or_sls_bottleneck(self) -> None:
        for cpu, nic, sls, packets, expected in (
            (85, 100, 30, [0, 100, 500], True),
            (84.9, 100, 30, [0, 100, 500], False),
            (90, 301, 30, [0, 100, 500], False),
            (90, 100, 70, [0, 100, 500], False),
            (90, 100, 30, [0, 100, 300], False),
        ):
            fixture = capacity_fixture()
            fixture["cells"][0].update(
                per_core_cpu_pct=[cpu, 20],
                nic_in_mbps=nic,
                sls_cpu_pct=sls,
                packets_received=packets,
            )
            with self.subTest(cpu=cpu, nic=nic, sls=sls, packets=packets):
                self.assertEqual(capacity_probe.evaluate(fixture)["cpu_bound"], expected)

    def test_thresholds_and_faults_remove_capacity(self) -> None:
        for field, value in (
            ("duration_s", 1799),
            ("per_core_cpu_pct", [70]),
            ("nic_out_mbps", 301),
            ("pps_in", 60001),
            ("udp_receive_errors", [0, 0, 1]),
            ("rss_bytes", [1000, 1200, 1400]),
            ("delivered_goodput_mbps", 94.9),
            ("auth_failures", 1),
            ("evictions", 1),
            ("disconnects", 1),
        ):
            fixture = capacity_fixture()
            fixture["cells"][0][field] = value
            with self.subTest(field=field):
                self.assertEqual(capacity_probe.evaluate(fixture)["softCapBonds"], 0)

    def test_goodput_boundary_and_stock_rss_growth_are_preserved(self) -> None:
        fixture = capacity_fixture()
        for cell in fixture["cells"]:
            cell.update(
                delivered_goodput_mbps=95,
                rss_bytes=[1000, 1100, 1200],
                stock_rss_bytes=[1000, 1100, 1200],
            )
        self.assertEqual(capacity_probe.evaluate(fixture)["softCapBonds"], 25)

    def test_invalid_and_duplicate_metrics_are_rejected(self) -> None:
        for mutate in (
            lambda f: f.update(per_bond_pps_6mbps=0),
            lambda f: f["cells"][0].update(bonds=201),
            lambda f: f["cells"][0].update(nic_in_mbps=float("nan")),
            lambda f: f["cells"][0].update(packets_received=[100, 0, 300]),
            lambda f: f["cells"][0].update(recv_batches=[0, 0, 0]),
            lambda f: f["cells"].append(copy.deepcopy(f["cells"][0])),
            lambda f: f.update(source="live"),
        ):
            fixture = capacity_fixture()
            mutate(fixture)
            with self.subTest(mutate=mutate), self.assertRaises(ValueError):
                capacity_probe.evaluate(fixture)


class DnsTests(unittest.TestCase):
    def test_control_per_relay_stale_cache_and_dual_stack_are_distinct(self) -> None:
        result = sender_dns.evaluate(dns_fixture())
        self.assertEqual(result["control_split_detected"], True)
        self.assertEqual(result["per_relay_single_answer"], True)
        self.assertEqual(result["split_during_change"], True)
        self.assertEqual(result["dual_stack_safe"], False)
        self.assertEqual(result["qualified"], False)
        for sender in sender_dns.SENDERS:
            self.assertEqual(result["senders"][sender]["resolution"], "per_network")

    def test_per_relay_answer_is_shared_across_senders_for_each_hostname(self) -> None:
        for hostname, expected in (
            ("r-abcdefghij.ingest.example.test", False),
            ("r-0123456789.ingest.example.test", True),
        ):
            fixture = dns_fixture()
            for row in fixture["observations"]:
                if row["sender"] == "ceraui-resolveSrtla" and row["scenario"] == "per_relay":
                    row["hostname"] = hostname
                    for uplink in row["uplinks"]:
                        uplink.update(address="192.0.2.2", cname_chain=["g2-mia"])
            result = sender_dns.evaluate(fixture)
            with self.subTest(hostname=hostname):
                self.assertEqual(result["per_relay_single_answer"], expected)
                self.assertEqual(result["winner"], "a_only" if expected else "insufficient")
                self.assertEqual(
                    [result["senders"][sender]["per_relay_single_answer"] for sender in sender_dns.SENDERS],
                    [True, True, True, True],
                )

    def test_emitted_moblin_pin_matches_the_registry_exactly(self) -> None:
        registry = yaml.safe_load((SCENARIOS.parent / "matrix.yaml").read_text(encoding="utf-8"))
        pin = next(sender["pin"] for sender in registry["senders"] if sender["name"] == "moblin-mock")
        self.assertEqual(sender_dns.evaluate(dns_fixture())["moblin_mock_pin"], pin)

    def test_single_resolver_query_proves_resolve_once(self) -> None:
        fixture = dns_fixture()
        observation = fixture["observations"][0]
        observation["resolver_queries"] = ["resolver-0"]
        observation["uplinks"][1]["address"] = "192.0.2.1"
        result = sender_dns.evaluate(fixture)
        self.assertEqual(result["senders"][sender_dns.SENDERS[0]]["resolution"], "resolve_once")

    def test_missing_evidence_stays_unknown_and_unsafe(self) -> None:
        fixture = dns_fixture()
        fixture["observations"] = fixture["observations"][1:3]
        result = sender_dns.evaluate(fixture)
        self.assertEqual(result["senders"][sender_dns.SENDERS[0]]["resolution"], "unknown")
        self.assertEqual(result["per_relay_single_answer"], False)
        self.assertEqual(result["dual_stack_safe"], False)
        self.assertEqual(result["winner"], "insufficient")

    def test_uniform_dual_stack_requires_all_cases_but_never_qualifies_fixture(self) -> None:
        fixture = dns_fixture()
        for row in fixture["observations"]:
            if row["scenario"] == "dual_stack":
                row["uplinks"][1].update(address="2001:db8::1", cname_chain=["g1-eu"])
        result = sender_dns.evaluate(fixture)
        self.assertEqual(result["fixture_dual_stack_safe"], True)
        self.assertEqual(result["dual_stack_safe"], False)
        self.assertEqual(result["qualified"], False)

    def test_missing_control_split_is_not_passed(self) -> None:
        fixture = dns_fixture()
        for row in fixture["observations"]:
            if row["scenario"] == "control":
                row["uplinks"][1]["address"] = row["uplinks"][0]["address"]
                row["resolver_queries"] = ["resolver-0"]
        result = sender_dns.evaluate(fixture)
        self.assertEqual(
            [result["senders"][sender]["resolution"] for sender in sender_dns.SENDERS],
            ["resolve_once", "resolve_once", "resolve_once", "resolve_once"],
        )
        self.assertEqual(result["control_split_detected"], False)
        self.assertEqual(result["winner"], "insufficient")

    def test_unknown_resolution_cannot_pass_a_complete_fixture(self) -> None:
        fixture = dns_fixture()
        control = fixture["observations"][0]
        control["uplinks"][1]["address"] = control["uplinks"][0]["address"]
        result = sender_dns.evaluate(fixture)
        self.assertEqual(result["senders"][sender_dns.SENDERS[0]]["resolution"], "unknown")
        self.assertEqual(result["winner"], "insufficient")

    def test_missing_stale_split_is_not_passed(self) -> None:
        fixture = dns_fixture()
        for row in fixture["observations"]:
            if row["scenario"] == "stale_cache":
                row["uplinks"][1].update(address="192.0.2.1", cname_chain=["g1-eu"])
        result = sender_dns.evaluate(fixture)
        self.assertEqual(result["split_during_change"], False)
        self.assertEqual(result["winner"], "insufficient")

    def test_wrong_family_or_missing_nat64_remains_unsafe(self) -> None:
        self.assertEqual(sender_dns.SCENARIOS[3:], ("a_only", "aaaa_only", "dual_stack", "nat64"))
        actual = {}
        for scenario in ("a_only", "aaaa_only", "dual_stack", "nat64"):
            fixture = dns_fixture()
            for row in fixture["observations"]:
                if row["scenario"] == "dual_stack":
                    row["uplinks"][1].update(address="2001:db8::1", cname_chain=["g1-eu"])
                if row["scenario"] == scenario:
                    for uplink in row["uplinks"]:
                        uplink.update(
                            address="2001:db8::1" if scenario == "a_only" else "192.0.2.1",
                            cname_chain=["g1-eu"],
                        )
            actual[scenario] = sender_dns.evaluate(fixture)["fixture_dual_stack_safe"]
        self.assertEqual(actual, {
            "a_only": False,
            "aaaa_only": False,
            "dual_stack": False,
            "nat64": False,
        })

    def test_bad_cname_chain_and_unknown_address_fail_closed(self) -> None:
        for mutate in (
            lambda f: f["observations"][1]["uplinks"][0].update(cname_chain=["g1-eu", "g2-mia"]),
            lambda f: f["observations"][1]["uplinks"][0].update(address="192.0.2.99"),
            lambda f: f["observations"][1].update(hostname="g1-eu.ingest.example.test"),
            lambda f: f["observations"].append(copy.deepcopy(f["observations"][0])),
        ):
            fixture = dns_fixture()
            mutate(fixture)
            with self.subTest(mutate=mutate), self.assertRaises(ValueError):
                sender_dns.evaluate(fixture)

    def test_phone_apps_remain_unverified(self) -> None:
        result = sender_dns.evaluate(dns_fixture())
        self.assertEqual(set(result["unverified_apps"]), {"IRL Pro", "Larix", "OBS SRTLA forks", "BELABOX"})
        self.assertTrue(all(row["status"] == "UNVERIFIED" for row in result["unverified_apps"].values()))


class CliTests(unittest.TestCase):
    def test_live_modes_skip_without_creating_output(self) -> None:
        for script, arguments in (
            ("capacity-probe.sh", []),
            ("capacity-probe.sh", ["--real-host"]),
            ("sender-dns.sh", []),
            ("sender-dns.sh", ["--live"]),
        ):
            with self.subTest(script=script, arguments=arguments):
                result = subprocess.run(
                    ["bash", str(SCENARIOS / script), *arguments],
                    capture_output=True, text=True, timeout=10, check=False,
                )
                self.assertEqual(result.returncode, 77, result.stderr)
                self.assertEqual(json.loads(result.stdout)["status"], "SKIP")
                self.assertIn("missing_", json.loads(result.stdout)["reason"])

    def test_fixture_cli_writes_recomputable_verdict_and_refuses_overwrite(self) -> None:
        for script, fixture in (
            ("capacity-probe.sh", capacity_fixture()),
            ("sender-dns.sh", dns_fixture()),
        ):
            with self.subTest(script=script), tempfile.TemporaryDirectory() as directory:
                source = Path(directory) / "fixture.json"
                target = Path(directory) / "verdict.json"
                source.write_text(json.dumps(fixture), encoding="utf-8")
                command = ["bash", str(SCENARIOS / script), "--fixture", str(source), "--output", str(target)]
                result = subprocess.run(command, capture_output=True, text=True, timeout=10, check=False)
                self.assertEqual(result.returncode, 0, result.stderr)
                verdict = json.loads(target.read_text(encoding="utf-8"))
                self.assertEqual(verdict["source"], "fixture")
                self.assertEqual(len(verdict["rule_sha256"]), 64)
                self.assertEqual(len(verdict["input_sha256"]), 64)
                repeated = subprocess.run(command, capture_output=True, text=True, timeout=10, check=False)
                self.assertEqual(repeated.returncode, 2)

    def test_invalid_and_incomplete_cli_inputs_are_not_passed(self) -> None:
        for fixture, expected in (({"source": "live"}, 2), (capacity_fixture(), 1)):
            if "cells" in fixture:
                fixture["cells"].pop()
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as directory:
                source = Path(directory) / "fixture.json"
                target = Path(directory) / "verdict.json"
                source.write_text(json.dumps(fixture), encoding="utf-8")
                result = subprocess.run(
                    ["bash", str(SCENARIOS / "capacity-probe.sh"), "--fixture", str(source), "--output", str(target)],
                    capture_output=True, text=True, timeout=10, check=False,
                )
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(target.exists(), expected == 1)


class LiveTests(unittest.TestCase):
    def test_live_observe_launches_one_bonded_sender_for_both_uplinks(self) -> None:
        # Loopback substitutes for link namespaces; launches, packets and PID
        # attribution remain real, with capture sockets opened before launch.
        for scenario in ("control", "per_relay"):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as directory, Processes() as holders:
                root = Path(directory)
                sender = root / "bonded-sender.py"
                sender.write_text(
                    "import signal, socket, sys\n"
                    "from pathlib import Path\n"
                    "links = {'10.203.0.2': (0, '127.0.0.2', '127.0.1.1'),"
                    " '10.204.0.2': (1, '127.0.0.3', '127.0.1.2')}\n"
                    "sockets = []\n"
                    "for ip in Path(sys.argv[1]).read_text().splitlines():\n"
                    "    index, source, destination = links[ip]\n"
                    "    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)\n"
                    "    sock.bind((source, 0))\n"
                    "    sockets.append(sock)\n"
                    "    sock.sendto(b'\\x90\\x00' + bytes(8),"
                    " (destination, int(sys.argv[2 + index])))\n"
                    "signal.pause()\n",
                    encoding="utf-8",
                )
                lab = sender_dns_live.Lab(root, holders, 43060)
                children = []
                ip_files = []
                original_start = Processes.start
                original_iterdir = Path.iterdir

                def launch(owner, command, log, *args, **kwargs):
                    ip_files.append(Path(command[2]).read_text().splitlines())
                    child = original_start(owner, command, log, *args, **kwargs)
                    children.append(child)
                    return child

                def visible_processes(path):
                    # A private PID namespace exposes only its own processes.
                    # Read actual UDP inodes and child FDs, not invented owners.
                    if path == Path("/proc"):
                        return iter(Path(f"/proc/{child.pid}") for child in children)
                    return original_iterdir(path)

                try:
                    lab.listen(0, "127.0.1.1", 0, "srtla", "g1-lab")
                    lab.listen(1, "127.0.1.2", 0, "srtla", "g1-lab")
                    ports = [
                        key.fileobj.getsockname()[1]
                        for key in lab.selector.get_map().values()
                    ]
                    command = {
                        "boundary": "bonded-process",
                        "argv": [sys.executable, str(sender), "{ips_file}", *map(str, ports)],
                    }
                    with patch.object(Processes, "start", autospec=True, side_effect=launch) as started, \
                            patch.object(Path, "iterdir", visible_processes):
                        observed = lab.observe("c-srtla-send", command, scenario, 5)
                    started.assert_called_once()
                    self.assertEqual(ip_files, [["10.203.0.2", "10.204.0.2"]])
                    self.assertEqual(observed["sender_pid"], children[0].pid)
                    self.assertEqual(observed["sender_instances"], 1)
                    self.assertEqual(observed["observed_socket_owner_pids"], [children[0].pid])
                    self.assertEqual(
                        {packet["path"] for packet in observed["packets"]}, {0, 1},
                    )
                    self.assertEqual(
                        {packet["socket_owner_pid"] for packet in observed["packets"]},
                        {children[0].pid},
                    )
                    self.assertTrue(all(path["address"] is not None for path in observed["uplinks"]))
                    self.assertTrue(all(child.poll() is not None for child in children))
                finally:
                    lab.resources.close()

    def test_successful_namespace_probe_launches_worker_and_returns_observations(self) -> None:
        observation = {
            "sender": "c-srtla-send", "sender_instances": 1,
            "observed_socket_owner_pids": [1234],
            "uplinks": [{"address": "198.18.0.1"}, {"address": "198.18.0.1"}],
        }
        observed = {
            "scenario": "G5", "source": "live", "status": "OBSERVED",
            "winner": "observed", "qualified": False, "observations": [observation],
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "config.json"
            config.write_text(json.dumps({
                "schema_version": 1, "requested": ["c-srtla-send"],
                "senders": {"c-srtla-send": {
                    "boundary": "bonded-process", "argv": [sys.executable, "{hostname}"],
                }},
            }))
            output = root / "verdict.json"
            calls = []

            def execute(command: list[str], **options) -> subprocess.CompletedProcess:
                calls.append(command)
                if len(calls) == 1:
                    self.assertEqual(command[:5], ["unshare", "--user", "--map-root-user", "--net", "--mount"])
                    self.assertNotIn("--worker", command)
                    self.assertEqual(options["timeout"], 10)
                    return subprocess.CompletedProcess(command, 0, "", "")
                self.assertEqual(len(calls), 2)
                self.assertIn("--worker", command)
                self.assertIn("--kill-child", command)
                self.assertEqual(options["timeout"], 1800)
                worker_config = json.loads(Path(command[-2]).read_text())
                self.assertEqual(worker_config["requested"], ["c-srtla-send"])
                self.assertEqual(worker_config["prerequisite_reasons"], [])
                return subprocess.CompletedProcess(command, 0, json.dumps(observed), "")

            with patch("sender_dns_live.require_tool", side_effect=lambda name: name), \
                    patch("sender_dns_live.subprocess.run", side_effect=execute), redirect_stdout(StringIO()):
                code = run_live("sender-dns", config, output, sender_dns.RULE)
            self.assertEqual(code, 0)
            self.assertEqual(len(calls), 2)
            result = json.loads(output.read_text())
            self.assertEqual(result["status"], "OBSERVED")
            self.assertEqual(result["observations"], [observation])
            self.assertEqual(result["observations"][0]["observed_socket_owner_pids"], [1234])

    def measured_cell(self, root: Path) -> tuple[dict, list]:
        """Keep the real sampling loop and assembly; replace only OS boundaries."""
        directory = root / "cell"
        media = directory / "delivered-0.ts"
        def cpu(user: int, idle: int) -> list[list[int]]:
            return [[user, 0, 0, idle, 0, 0, 0, 0, 0, 0]]
        nic_samples = [
            [100, 200, 10, 20], [100, 200, 10, 20],
            [2500100, 1250200, 1010, 520], [3500100, 1750200, 1210, 620],
        ]
        metric_samples = []
        for packets, batches in ((1000, 100), (1000, 100), (1600, 300), (2200, 500)):
            metric_samples.append({
                "srtla_packets_received_total": packets, "srtla_recv_batches_total": batches,
                "srtla_auth_failures_total": 0,
                **{f'srtla_groups_removed_total{{reason="{reason}"}}': 0
                   for reason in ("evicted", "idle_timeout", "srt_error", "auth_failed")},
            })
        original_read, original_iterdir = Path.read_text, Path.iterdir

        def proc_read(path: Path, *args, **kwargs) -> str:
            if path == Path("/proc/202/status"):
                return "VmRSS:\t42 kB\n"
            return original_read(path, *args, **kwargs)

        def proc_fds(path: Path):
            if path == Path("/proc/202/fd"):
                return iter([Path("fd0"), Path("fd1")])
            return original_iterdir(path)

        config = {
            "duration_s": 2, "samples": 3, "receiver_core": 0,
            "interface": "test-uplink", "link_addresses": ["127.0.0.1"],
            "receiver": sys.executable,
            "sls": {"argv": [sys.executable, "sls"]},
            "sink": {"argv": [sys.executable, "sink", "{media_file}"]},
            "sender": {"argv": [sys.executable, "sender"]},
            "load": {"argv": [sys.executable, "load"], "ready": "first-media"},
        }
        with patch("capacity_live.Processes") as factory, \
                patch("capacity_live.require_tool", side_effect=lambda name: name), \
                patch("capacity_live.cpu_counters", side_effect=[cpu(0, 100), cpu(0, 100), cpu(10, 190), cpu(30, 270)]), \
                patch("capacity_live.nic_counters", side_effect=nic_samples), \
                patch("capacity_live.process_ticks", side_effect=[10, 20, 10, 20, 15, 25, 25, 40]), \
                patch("capacity_live.metrics", side_effect=metric_samples), \
                patch("capacity_live.udp_errors", return_value=5), \
                patch("capacity_live.time.monotonic", side_effect=[0, 0, 1, 1, 2, 2, 2]), \
                patch("capacity_live.threading.Event.wait", side_effect=lambda delay: self.assertEqual(delay, 0)), \
                patch.object(Path, "read_text", proc_read), patch.object(Path, "iterdir", proc_fds):
            processes = factory.return_value.__enter__.return_value
            processes.bytes = {505: 0}

            def launch(command: list[str], *args, **kwargs):
                if "sink" in command:
                    media.write_bytes(b"")
                return SimpleNamespace(pid=(101, 202, 303, 404, 505)[processes.start.call_count - 1])

            def sample() -> None:
                delivered = (0, 750000, 1500000)[processes.alive.call_count - 1]
                processes.bytes[505] = delivered
                with media.open("r+b") as destination:
                    destination.truncate(delivered)

            processes.start.side_effect = launch
            processes.alive.side_effect = sample
            cell = capacity_live.measure(config, directory, 1, 6, 1)
            self.assertEqual(processes.start.call_count, 5)
            self.assertEqual(processes.alive.call_count, 3)
        return cell, json.loads((directory / "samples.json").read_text())

    def test_measure_emits_exact_peak_nic_mbps_from_sampled_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            cell, samples = self.measured_cell(Path(directory))
        self.assertEqual(cell["nic_in_mbps"], 20.0)
        self.assertEqual(cell["nic_out_mbps"], 10.0)
        for field, index in (("nic_in_mbps", 0), ("nic_out_mbps", 1)):
            independently_measured = max(
                (b["nic"][index] - a["nic"][index]) * 8 / 1e6 / (b["elapsed_s"] - a["elapsed_s"])
                for a, b in zip(samples, samples[1:])
            )
            self.assertEqual(cell[field], independently_measured)

    def test_measure_emits_exact_peak_pps_from_sampled_packets(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            cell, samples = self.measured_cell(Path(directory))
        self.assertEqual(cell["pps_in"], 1000.0)
        self.assertEqual(cell["pps_out"], 500.0)
        for field, index in (("pps_in", 2), ("pps_out", 3)):
            independently_measured = max(
                (b["nic"][index] - a["nic"][index]) / (b["elapsed_s"] - a["elapsed_s"])
                for a, b in zip(samples, samples[1:])
            )
            self.assertEqual(cell[field], independently_measured)

    def test_complete_h1_config_dispatches_capture_and_emits_measured_matrix(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "binary"
            executable.write_bytes(b"test executable identity\n")
            executable.chmod(0o755)
            config = {
                "schema_version": 1, "interface": "lo", "provider_class": "test:measured",
                "sender_ref": "main", "sender_sha": "1" * 40, "receiver": str(executable),
                "sender": {"argv": [str(executable)]}, "sls": {}, "sink": {}, "load": {},
                "preview": {}, "calibration": {}, "link_addresses": ["127.0.0.1"], "bonds": [25],
            }
            fixture = capacity_fixture()

            def collect(actual_config, output, bonds, bitrate, links):
                self.assertEqual(actual_config["interface"], "lo")
                self.assertEqual(bonds, 25)
                cell = copy.deepcopy(next(
                    cell for cell in fixture["cells"]
                    if cell["bitrate_mbps"] == bitrate and cell["links"] == links
                ))
                cell.update(offered_goodput_mbps=bonds * bitrate, receiver_cpu_pct=40)
                return cell

            source, output = root / "config.json", root / "verdict.json"
            source.write_text(json.dumps(config))
            with patch("capacity_live.calibrate", return_value=(
                fixture["sustainable_nic_mbps"], fixture["sustainable_pps"], [],
            )) as calibrated, patch("capacity_live.measure", side_effect=collect) as measured, \
                    patch("capacity_live.preview_trials", return_value=fixture["preview_trials"]), \
                    redirect_stdout(StringIO()):
                code = run_live("relay-capacity-probe", source, output, capacity_probe.RULE)
            self.assertEqual(code, 0)
            calibrated.assert_called_once()
            self.assertEqual(measured.call_count, 18)
            result = json.loads(output.read_text())
            self.assertEqual(result["status"], "MEASURED")
            self.assertEqual(result["source"], "real-host")
            self.assertEqual(result["winner"], "measured_capacity")
            self.assertEqual(result["softCapBonds"], 25)
            self.assertEqual(len(result["cells"]), 9)
            self.assertEqual(
                {(cell["bitrate_mbps"], cell["links"]) for cell in result["cells"]},
                capacity_probe.MATRIX,
            )
            retained = json.loads((root / "verdict-artifacts/measurements.json").read_text())
            self.assertEqual(retained["source"], "real-host")
            self.assertEqual(len(retained["cells"]), 9)

    def test_other_workstation_port_allocations_do_not_extend_this_contract(self) -> None:
        for invalid in (47000, 47499):
            with self.subTest(port=invalid), self.assertRaises(ValueError):
                port(invalid)

    def test_sender_exit_is_an_exact_selector_event_without_datagrams(self) -> None:
        with tempfile.TemporaryDirectory() as directory, Processes() as processes:
            lab = sender_dns_live.Lab(Path(directory), processes, 43060)
            try:
                with subprocess.Popen(
                    [sys.executable, "-c", "import sys; sys.stdin.readline()"],
                    stdin=subprocess.PIPE,
                ) as child, os.fdopen(os.pidfd_open(child.pid), "rb") as exited:
                    lab.selector.register(exited, selectors.EVENT_READ, (-1, "", "process-exit", child.pid))
                    child.stdin.write(b"exit\n")
                    child.stdin.flush()
                    lab.receive(5)
                    self.assertIn(child.pid, lab.exited)
                    self.assertEqual(child.wait(timeout=5), 0)
                    lab.selector.unregister(exited)
            finally:
                lab.resources.close()

    def test_calibration_counts_srt_sized_datagrams_in_both_directions(self) -> None:
        result = {"end": {"sum": {
            "seconds": 1, "packets": 1900, "lost_packets": 0, "bits_per_second": 20e6,
        }}}
        with tempfile.TemporaryDirectory() as directory, \
                patch("capacity_live.require_tool", return_value="/fixture/iperf3"), \
                patch("capacity_live.nic_counters", side_effect=[
                    [0, 0, 0, 0], [2500000, 2500000, 2000, 2000],
                    [0, 0, 0, 0], [2500000, 2500000, 2000, 2000],
                ]), \
                patch("capacity_live.time.monotonic", side_effect=[0, 1, 2, 3]), \
                patch("capacity_live.subprocess.run", return_value=subprocess.CompletedProcess(
                    [], 0, json.dumps(result), "",
                )) as invoked:
            nic, pps, _ = capacity_live.calibrate({
                "interface": "fixture", "calibration": {
                    "host": "127.0.0.1", "port": 43000, "duration_s": 1, "offered_mbps": [20],
                },
            }, Path(directory))
            self.assertEqual(nic, {"in": 20, "out": 20})
            self.assertEqual(pps, {"in": 1900, "out": 1900})
            commands = [call.args[0] for call in invoked.call_args_list]
            for command in commands:
                self.assertEqual(command[command.index("-l") + 1], "1316")
            self.assertIn("-R", commands[0])
            self.assertNotIn("-R", commands[1])

    def test_nic_capture_uses_current_network_namespace_counter_layout(self) -> None:
        counters = (
            "Inter-| Receive | Transmit\n face |bytes packets errs drop fifo frame compressed multicast|bytes packets errs\n"
            " uplink0: 131600 100 0 0 0 0 0 0 263200 200 0 0 0 0 0 0\n"
        )
        self.assertEqual(capacity_live.parse_nic_counters(counters, "uplink0"), [131600, 263200, 100, 200])
        with self.assertRaises(PrerequisiteError) as absent:
            capacity_live.parse_nic_counters(counters, "host-only")
        self.assertEqual(str(absent.exception), "missing_nic:host-only")

    def test_real_capture_cannot_label_underload_as_a_twenty_mbps_cell(self) -> None:
        measurement = capacity_fixture()
        measurement["source"] = "real-host"
        for cell in measurement["cells"]:
            cell["offered_goodput_mbps"] = cell["bonds"] * cell["bitrate_mbps"]
            cell["receiver_cpu_pct"] = 40
        self.assertEqual(capacity_probe.evaluate(measurement, captured=True)["softCapBonds"], 25)
        measurement["cells"][-1]["offered_goodput_mbps"] = 100
        self.assertEqual(capacity_probe.evaluate(measurement, captured=True)["softCapBonds"], 0)
        with self.assertRaises(ValueError):
            capacity_probe.evaluate(measurement)

    def test_real_cpu_bound_requires_the_receiver_not_an_unrelated_busy_core(self) -> None:
        measurement = capacity_fixture()
        measurement["source"] = "real-host"
        for cell in measurement["cells"]:
            cell["offered_goodput_mbps"] = cell["bonds"] * cell["bitrate_mbps"]
            cell["receiver_cpu_pct"] = 40
        measurement["cells"][0].update(per_core_cpu_pct=[90, 20], packets_received=[0, 100, 500])
        self.assertFalse(capacity_probe.evaluate(measurement, captured=True)["cpu_bound"])
        measurement["cells"][0]["receiver_cpu_pct"] = 85
        self.assertTrue(capacity_probe.evaluate(measurement, captured=True)["cpu_bound"])

    def test_cpu_and_nic_metrics_are_counter_deltas(self) -> None:
        self.assertEqual(capacity_live.counter_rates([10, 20], [30, 60], 2), [10, 20])
        self.assertEqual(
            capacity_live.cpu_usage([[10, 0, 0, 90, 0, 0, 0, 0, 0, 0]],
                                    [[40, 0, 0, 160, 0, 0, 0, 0, 0, 0]]),
            [30],
        )

    def test_counter_resets_and_invalid_windows_fail(self) -> None:
        for before, after, window in (([1], [0], 1), ([0], [1], 0), ([0], [1, 2], 1)):
            with self.subTest(window=window), self.assertRaises(ValueError):
                capacity_live.counter_rates(before, after, window)

    def test_iperf_loss_cannot_create_sustainable_capacity(self) -> None:
        measurement = {"end": {"sum": {
            "seconds": 2, "packets": 100, "lost_packets": 0, "bits_per_second": 6e6,
        }}}
        self.assertEqual(capacity_live.iperf_result(measurement, 0.1), (6, 50))
        measurement["end"]["sum"]["lost_packets"] = 1
        self.assertEqual(capacity_live.iperf_result(measurement, 0.1), (0, 0))

    def test_port_range_is_enforced_before_starting_services(self) -> None:
        self.assertEqual(port(43000), 43000)
        self.assertEqual(port(43999), 43999)
        for invalid in (42999, 44000, 100000):
            with self.subTest(port=invalid), self.assertRaises(ValueError):
                port(invalid)

    def test_one_resolve_once_process_is_not_per_network(self) -> None:
        observation = {
            "sender_instances": 1, "resolver_queries": ["resolver-0"],
            "uplinks": [{"address": "198.18.0.1"}, {"address": "198.18.0.1"}],
        }
        self.assertEqual(sender_dns_live.classify(observation), "resolve_once")
        observation["resolver_queries"].append("resolver-0")
        self.assertEqual(sender_dns_live.classify(observation), "unknown")
        observation["sender_instances"] = 2
        observation["resolver_queries"] = ["resolver-0", "resolver-1"]
        observation["uplinks"][1]["address"] = "198.18.0.2"
        self.assertEqual(sender_dns_live.classify(observation), "unknown")

    def test_per_network_requires_both_wire_destinations_and_resolvers(self) -> None:
        observation = {
            "sender_instances": 1, "resolver_queries": ["resolver-0", "resolver-1"],
            "uplinks": [{"address": "198.18.0.1"}, {"address": "198.18.0.2"}],
        }
        self.assertEqual(sender_dns_live.classify(observation), "per_network")
        observation["resolver_queries"] = ["resolver-0"]
        self.assertEqual(sender_dns_live.classify(observation), "unknown")
        observation["uplinks"][1]["address"] = None
        self.assertEqual(sender_dns_live.classify(observation), "unknown")

    def test_socket_attribution_reads_real_kernel_endpoint_and_inode_fields(self) -> None:
        content = (
            "sl local_address rem_address st tx_queue tr retrnsmt uid timeout inode\n"
            "1: 0200CB0A:A878 00000000:0000 07 0:0 0:0 0 0 0 12345\n"
        )
        self.assertEqual(sender_dns_live.socket_inodes(content, socket.AF_INET), {
            ("10.203.0.2", 43128): "12345",
        })

    def test_independent_resolver_cache_retains_old_answer_after_change(self) -> None:
        query = (b"\0\1\1\0\0\1\0\0\0\0\0\0"
                 + sender_dns_live.dns_name("r-abcdefghij.ingest.test") + b"\0\1\0\1")
        old = sender_dns_live.Resolver(0, "stale_cache")
        new = sender_dns_live.Resolver(1, "stale_cache")
        old.answer(query, 0)
        new.answer(query, 0)
        old.authority = new.authority = "g2-lab"
        new.cache.clear()
        self.assertEqual(old.answer(query, 1)[1]["answer"], "198.18.0.1")
        self.assertEqual(new.answer(query, 1)[1]["answer"], "198.18.0.2")
        self.assertEqual(old.answer(query, 61)[1]["answer"], "198.18.0.2")

    def test_cname_is_one_cached_alias_across_address_families(self) -> None:
        header = b"\0\1\1\0\0\1\0\0\0\0\0\0"
        hostname = sender_dns_live.dns_name("r-abcdefghij.ingest.test")
        query_a = header + hostname + b"\0\1\0\1"
        query_aaaa = header + hostname + b"\0\x1c\0\1"
        resolver = sender_dns_live.Resolver(0, "dual_stack")
        self.assertEqual(resolver.answer(query_a, 0)[1]["cname_chain"], ["g1-lab"])
        response = resolver.answer(query_aaaa, 1)[1]
        self.assertEqual(response["cname_chain"], ["g1-lab"])
        self.assertEqual(response["answer"], "fd73:100::2")
        resolver.authority = "g2-lab"
        self.assertEqual(resolver.answer(query_aaaa, 2)[1]["cname_chain"], ["g1-lab"])
        self.assertEqual(resolver.answer(query_aaaa, 61)[1]["cname_chain"], ["g2-lab"])

    def test_dns_wire_answers_exercise_family_and_cname_cases(self) -> None:
        header = b"\0\1\1\0\0\1\0\0\0\0\0\0"
        hostname = sender_dns_live.dns_name("r-abcdefghij.ingest.test")
        for scenario, qtype, address, answers in (
            ("a_only", 1, "198.18.0.1", 2),
            ("a_only", 28, None, 1),
            ("aaaa_only", 1, None, 1),
            ("aaaa_only", 28, "fd73:100::1", 2),
            ("dual_stack", 28, "fd73:100::2", 2),
            ("nat64", 28, "64:ff9b::c612:1", 2),
        ):
            with self.subTest(scenario=scenario, qtype=qtype):
                response, record = sender_dns_live.Resolver(1, scenario).answer(
                    header + hostname + struct.pack("!HH", qtype, 1), 0,
                )
                self.assertEqual(record["answer"], address)
                self.assertEqual(struct.unpack("!H", response[6:8])[0], answers)

    def test_partial_live_evidence_never_enables_aaaa_or_qualifies_provider(self) -> None:
        result = sender_dns_live.verdict([], ["c-srtla-send"], ["missing_sender_command:c-srtla-send"])
        self.assertEqual(result["status"], "SKIP")
        self.assertEqual(result["senders"]["c-srtla-send"]["resolution"], "unknown")
        self.assertFalse(result["per_relay_single_answer"])
        self.assertFalse(result["dual_stack_safe"])
        self.assertFalse(result["qualified"])

    def test_live_family_gate_requires_node_identity_families_and_actual_translation(self) -> None:
        def observed(addresses: list[str]) -> dict:
            return {
                "sender_instances": 1,
                "uplinks": [{"address": address, "node": "g1-lab"} for address in addresses],
                "packets": [{"path": -1}],
            }
        cases = {
            "a_only": observed(["198.18.0.1", "198.18.0.1"]),
            "aaaa_only": observed(["fd73:100::1", "fd73:100::1"]),
            "dual_stack": observed(["198.18.0.1", "fd73:100::1"]),
            "nat64": observed(["198.18.0.1", "64:ff9b::c612:1"]),
        }
        self.assertTrue(sender_dns_live.family_safety(cases))
        cases["nat64"]["packets"] = []
        self.assertFalse(sender_dns_live.family_safety(cases))
        cases["nat64"]["packets"] = [{"path": -1}]
        cases["dual_stack"]["uplinks"][1]["node"] = "g2-lab"
        self.assertFalse(sender_dns_live.family_safety(cases))

    def test_missing_capture_prerequisite_is_named_and_retained(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, target = root / "config.json", root / "verdict.json"
            source.write_text('{"schema_version":1}', encoding="utf-8")
            result = subprocess.run([
                "bash", str(SCENARIOS / "capacity-probe.sh"), "--real-host",
                "--config", str(source), "--output", str(target),
            ], capture_output=True, text=True, timeout=10, check=False)
            self.assertEqual(result.returncode, 77)
            self.assertEqual(json.loads(target.read_text())["reason"], "missing_h1_config:interface")
            repeated = subprocess.run([
                "bash", str(SCENARIOS / "capacity-probe.sh"), "--real-host",
                "--config", str(source), "--output", str(target),
            ], capture_output=True, text=True, timeout=10, check=False)
            self.assertEqual(repeated.returncode, 2)

    def test_namespace_denial_is_named_skip_without_faking_observations(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("unshare", "ip", "nsenter", "mount"):
                executable = root / name
                executable.write_text("#!/bin/sh\nexit 1\n" if name == "unshare" else "#!/bin/sh\nexit 0\n")
                executable.chmod(0o755)
            config = root / "config.json"
            config.write_text('{"schema_version":1,"senders":{}}')
            target = root / "verdict.json"
            result = subprocess.run([
                "bash", str(SCENARIOS / "sender-dns.sh"), "--live",
                "--config", str(config), "--output", str(target),
            ], capture_output=True, text=True, timeout=10, check=False,
                env={**os.environ, "PATH": str(root) + ":" + os.environ["PATH"]})
            self.assertEqual(result.returncode, 77)
            evidence = json.loads(target.read_text())
            self.assertTrue(evidence["reason"].startswith("user_network_mount_namespaces_denied:"))
            self.assertNotIn("observations", evidence)

    def test_process_ready_event_and_cleanup_do_not_depend_on_sleep(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with Processes() as processes:
                child = processes.start(
                    [sys.executable, "-c", "import signal; print('READY', flush=True); signal.pause()"],
                    Path(directory) / "child.log", "READY",
                )
                self.assertIsNone(child.poll())
            self.assertIsNotNone(child.poll())

    def test_application_probe_uses_real_export_and_forwards_cold_choice_unchanged(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            helper = root / "application.mjs"
            helper.write_text(
                "let calls = 0; export async function resolveSrtla(name) {"
                "return calls++ === 0 ? name : '198.18.0.1'; }",
                encoding="utf-8",
            )
            sender = root / "sender"
            sender.write_text(
                "#!/usr/bin/env python3\nimport json,sys\nprint(json.dumps({'dial_argv':sys.argv[1:]}))\n",
                encoding="utf-8",
            )
            sender.chmod(0o755)
            result = subprocess.run([
                shutil.which("bun") or "bun",
                str(Path(sender_dns_live.__file__).with_name("ceraui-resolver-probe.mjs")),
                str(helper), str(sender), "43061", "r-abcdefghij.ingest.test", "43060", "ips.txt",
            ], capture_output=True, text=True, check=True, timeout=10, cwd=root)
            events = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual(events, [
                {"phase": "cold", "selected": "r-abcdefghij.ingest.test"},
                {"phase": "warm", "selected": "198.18.0.1"},
                {"dial_argv": ["43061", "r-abcdefghij.ingest.test", "43060", "ips.txt"]},
            ])

    def test_application_probe_requires_its_actual_boot_setup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            module = Path(directory) / "srtla.ts"
            module.write_text("export const resolveSrtla = async name => name;\n")
            with self.assertRaises(PrerequisiteError) as missing:
                sender_dns_live.launch_command(
                    "ceraui-resolveSrtla", {"helper_module": str(module)}, {},
                )
            self.assertEqual(str(missing.exception), "missing_ceraui_setup_file:setup_file config")


if __name__ == "__main__":
    unittest.main()

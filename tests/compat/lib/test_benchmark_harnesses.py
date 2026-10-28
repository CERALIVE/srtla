#!/usr/bin/env python3
"""Deterministic H1/G5 fixtures; no sockets, providers or privileges."""

from __future__ import annotations

import copy
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

import capacity_probe
import sender_dns

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


if __name__ == "__main__":
    unittest.main()

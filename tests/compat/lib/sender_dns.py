#!/usr/bin/env python3
"""G5 resolver-observation fixtures, never live DNS qualification."""

from __future__ import annotations

import ipaddress
import re
from typing import Final

from benchmark_fixture_io import (
    Json, JsonMap, fixture_document, mapping, rows, run, text,
)

SENDERS: Final = ("c-srtla-send", "moblin-mock", "srtla-send-rs", "ceraui-resolveSrtla")
SCENARIOS: Final = ("control", "per_relay", "stale_cache", "a_only", "aaaa_only", "dual_stack", "nat64")
MOBLIN_PIN: Final = "0ae5294950166978064840bc874bfed3a8cf03a4"
NAT64: Final = ipaddress.IPv6Network("64:ff9b::/96")
RULE: Final = (
    "G5 v2: four automated senders x control/per_relay/stale_cache/"
    "a_only/aaaa_only/dual_stack/nat64; >=2 uplinks, each with its own resolver; "
    "control split plus >=2 observed resolvers => per_network; same destination "
    "plus exactly one observed resolver query => resolve_once; otherwise unknown; "
    "per-relay name r-<10 lowercase alphanumeric> is exactly one CNAME to a node A; "
    "all senders observing the same steady-state hostname must select one address; "
    "stale-cache splits are reported, never hidden; dual-stack requires all family "
    "cases to reach one server per case, including divergent A/AAAA and NAT64; "
    "unautomated phone apps remain UNVERIFIED; fixtures never enable AAAA."
)


def evaluate(value: Json) -> JsonMap:
    document = fixture_document(value)
    nodes = mapping(document["nodes"])
    addresses: dict[str, str] = {}
    for node, raw in nodes.items():
        if not re.fullmatch(r"g[1-9][0-9]*-[a-z0-9-]+", node):
            raise ValueError("node target must be a one-label g<N>-<location> name")
        pair = mapping(raw)
        for family, version in (("a", 4), ("aaaa", 6)):
            address = ipaddress.ip_address(text(pair[family]))
            canonical = str(address)
            if address.version != version or canonical in addresses:
                raise ValueError("node addresses must be unique and have the declared family")
            addresses[canonical] = node
    evidence: dict[tuple[str, str], JsonMap] = {}
    steady_answers: dict[str, set[str]] = {}
    for raw in rows(document["observations"]):
        observation = mapping(raw)
        sender, scenario = text(observation["sender"]), text(observation["scenario"])
        key = (sender, scenario)
        if sender not in SENDERS or scenario not in SCENARIOS or key in evidence:
            raise ValueError("unknown or duplicate sender/scenario")
        hostname = text(observation["hostname"])
        if scenario != "control" and not re.fullmatch(r"r-[a-z0-9]{10}\.ingest\.[a-z0-9.-]+", hostname):
            raise ValueError("G5 uses the automatic per-relay host, never an internal node host")
        destinations: set[str] = set()
        reached_addresses: set[str] = set()
        resolvers: set[str] = set()
        namespaces: set[str] = set()
        families: set[int] = set()
        nat64 = False
        for raw_uplink in rows(observation["uplinks"]):
            uplink = mapping(raw_uplink)
            namespace, resolver = text(uplink["namespace"]), text(uplink["resolver"])
            if namespace in namespaces or resolver in resolvers:
                raise ValueError("each uplink needs a distinct namespace and its own resolver")
            namespaces.add(namespace)
            resolvers.add(resolver)
            address = ipaddress.ip_address(text(uplink["address"]))
            reached_addresses.add(str(address))
            families.add(address.version)
            lookup = str(address)
            if isinstance(address, ipaddress.IPv6Address) and address in NAT64:
                lookup = str(ipaddress.IPv4Address(int(address) & 0xFFFFFFFF))
                nat64 = True
            if lookup not in addresses:
                raise ValueError("destination address does not identify a known node")
            node = addresses[lookup]
            destinations.add(node)
            if scenario != "control" and uplink["cname_chain"] != [node]:
                raise ValueError("per-relay answer must be exactly one CNAME to its destination node")
        if len(namespaces) < 2:
            raise ValueError("each scenario needs at least two independent uplinks")
        queries = [text(query) for query in rows(observation["resolver_queries"])]
        if not set(queries) <= resolvers:
            raise ValueError("query capture references an unknown resolver")
        single = len(destinations) == 1
        family_ok = (
            (scenario in ("control", "per_relay", "stale_cache", "a_only") and families == {4})
            or (scenario == "aaaa_only" and families == {6} and not nat64)
            or (scenario == "dual_stack" and families == {4, 6} and not nat64)
            or (scenario == "nat64" and nat64)
        )
        if scenario == "per_relay":
            steady_answers.setdefault(hostname, set()).update(reached_addresses)
        evidence[key] = {
            "single_node": single, "single_address": len(reached_addresses) == 1,
            "split": not single, "family_ok": family_ok,
            "queries": queries, "observation": observation,
        }
    senders: JsonMap = {}
    for sender in SENDERS:
        control = evidence.get((sender, "control"))
        resolution = "unknown"
        if control is not None:
            if control["split"] and len(set(text(q) for q in rows(control["queries"]))) >= 2:
                resolution = "per_network"
            elif control["single_address"] and len(rows(control["queries"])) == 1:
                resolution = "resolve_once"
        relay = evidence.get((sender, "per_relay"))
        stale = evidence.get((sender, "stale_cache"))
        family_cases = [evidence.get((sender, scenario)) for scenario in SCENARIOS[3:]]
        senders[sender] = {
            "resolution": resolution,
            "per_relay_single_answer": relay is not None and relay["single_address"] is True and relay["family_ok"] is True,
            "split_during_change": stale is not None and stale["split"] is True,
            "fixture_dual_stack_safe": all(
                row is not None and row["single_node"] is True and row["family_ok"] is True
                for row in family_cases
            ),
        }
    complete = len(evidence) == len(SENDERS) * len(SCENARIOS)
    per_relay = all(mapping(row)["per_relay_single_answer"] is True for row in senders.values()) and all(
        len(answers) == 1 for answers in steady_answers.values()
    )
    stale_split = any(mapping(row)["split_during_change"] is True for row in senders.values())
    control_split = any(
        row["split"] is True for (sender, scenario), row in evidence.items() if scenario == "control"
    )
    classified = all(mapping(row)["resolution"] != "unknown" for row in senders.values())
    fixture_safe = complete and classified and all(mapping(row)["fixture_dual_stack_safe"] is True for row in senders.values())
    return {
        "scenario": "G5", "source": "fixture", "qualified": False,
        "winner": "a_only" if complete and classified and per_relay and stale_split and control_split else "insufficient",
        "senders": senders, "control_split_detected": control_split,
        "per_relay_single_answer": per_relay, "split_during_change": stale_split,
        "fixture_dual_stack_safe": fixture_safe, "dual_stack_safe": False,
        "moblin_mock_pin": MOBLIN_PIN, "observations": document["observations"],
        "unverified_apps": {
            app: {"status": "UNVERIFIED", "reason": "real application/device run is not automated by this fixture harness"}
            for app in ("IRL Pro", "Larix", "OBS SRTLA forks", "BELABOX")
        },
    }


if __name__ == "__main__":
    raise SystemExit(run("sender-dns", evaluate, RULE, "DnsTests"))

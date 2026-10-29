"""One-process G5 wire-observation lab in disposable user/network namespaces."""

from __future__ import annotations

import ipaddress
import json
import os
import selectors
import signal
import socket
import struct
import subprocess
import sys
import time
from contextlib import ExitStack, contextmanager
from pathlib import Path

from benchmark_fixture_io import JsonMap, mapping, number, rows, text
from benchmark_live import Processes, PrerequisiteError, argv, port, require_tool
from sender_dns import MOBLIN_PIN, SCENARIOS, SENDERS

DNS4 = "10.205.0.53"
DNS6 = "fd73:53::53"
NODES = {
    "g1-lab": {"a": "198.18.0.1", "aaaa": "fd73:100::1"},
    "g2-lab": {"a": "198.18.0.2", "aaaa": "fd73:100::2"},
}


def dns_name(name: str) -> bytes:
    return b"".join(bytes([len(label)]) + label.encode("ascii") for label in name.split(".")) + b"\0"


def question(packet: bytes) -> tuple[str, int, bytes]:
    if len(packet) < 17 or struct.unpack("!H", packet[4:6])[0] != 1:
        raise ValueError("DNS requires one question")
    labels = []
    offset = 12
    while packet[offset]:
        length = packet[offset]
        if length > 63 or offset + length + 1 >= len(packet):
            raise ValueError("invalid DNS question")
        labels.append(packet[offset + 1:offset + 1 + length].decode("ascii"))
        offset += length + 1
    if len(packet) < offset + 5:
        raise ValueError("truncated DNS question")
    qtype, qclass = struct.unpack("!HH", packet[offset + 1:offset + 5])
    if qclass != 1:
        raise ValueError("DNS question must use IN class")
    return ".".join(labels).lower(), qtype, packet[12:offset + 5]


class Resolver:
    """An independently cached resolver with an explicitly mutable authority."""

    def __init__(self, path: int, scenario: str) -> None:
        self.path = path
        self.scenario = scenario
        self.authority = "g2-lab" if scenario == "control" and path else "g1-lab"
        self.cache: dict[str, tuple[float, str]] = {}

    def answer(self, packet: bytes, now: float) -> tuple[bytes, dict]:
        hostname, qtype, query = question(packet)
        key = hostname
        cached = key in self.cache and self.cache[key][0] > now
        node = self.cache[key][1] if cached else self.authority
        if not cached:
            self.cache[key] = (now + 60, node)
        alias_node = node
        records = []
        address = None
        if qtype == 1 and self.scenario != "aaaa_only" and not (self.scenario == "nat64" and self.path == 1):
            address = NODES[node]["a"]
        if qtype == 28 and self.scenario not in ("a_only", "per_relay", "stale_cache", "control"):
            if self.scenario == "dual_stack":
                node = "g2-lab"
            address = NODES[node]["aaaa"]
            if self.scenario == "nat64" and self.path == 1:
                address = str(ipaddress.IPv6Address(int(ipaddress.IPv6Address("64:ff9b::")) | int(ipaddress.IPv4Address(NODES[node]["a"]))))
        cname = self.scenario != "control" and hostname.startswith("r-") and qtype in (1, 28)
        if cname:
            target = dns_name(alias_node + ".ingest.test")
            records.append(b"\xc0\x0c" + struct.pack("!HHIH", 5, 1, 60, len(target)) + target)
        if address is not None:
            packed = ipaddress.ip_address(address).packed
            owner = dns_name(alias_node + ".ingest.test") if cname else b"\xc0\x0c"
            records.append(owner + struct.pack("!HHIH", qtype, 1, 60, len(packed)) + packed)
        if hostname == "wellknown.belabox.net" and qtype == 1:
            # CeraUI's real captive-portal validation must also cross the wire.
            address = "127.1.33.7"
            records = [b"\xc0\x0c" + struct.pack("!HHIH", 1, 1, 60, 4) + socket.inet_aton(address)]
        response = packet[:2] + struct.pack("!HHHHH", 0x8180, 1, len(records), 0, 0) + query + b"".join(records)
        return response, {
            "hostname": hostname, "qtype": qtype, "resolver": f"resolver-{self.path}",
            "cached": cached, "node": node, "answer": address, "cname_chain": [alias_node] if cname else [],
            "query_hex": packet.hex(), "response_hex": response.hex(),
        }


def classify(observation: dict) -> str:
    paths = observation["uplinks"]
    addresses = {row["address"] for row in paths if row["address"] is not None}
    queries = observation["resolver_queries"]
    if observation["sender_instances"] != 1 or len(paths) < 2 or any(row["address"] is None for row in paths):
        return "unknown"
    if len(addresses) > 1 and len(set(queries)) >= 2:
        return "per_network"
    if len(addresses) == 1 and len(queries) == 1:
        return "resolve_once"
    return "unknown"


def socket_inodes(content: str, family: int) -> dict[tuple[str, int], str]:
    endpoints = {}
    for line in content.splitlines()[1:]:
        fields = line.split()
        address_hex, service_port = fields[1].split(":")
        raw = bytes.fromhex(address_hex)
        if sys.byteorder == "little":
            raw = b"".join(raw[index:index + 4][::-1] for index in range(0, len(raw), 4))
        address = str(ipaddress.ip_address(socket.inet_ntop(family, raw)))
        endpoints[(address, int(service_port, 16))] = fields[9]
    return endpoints


def socket_owner(source: tuple) -> int | None:
    """Attribute the actual source socket, including descendants of an app launcher."""
    family, table = (socket.AF_INET6, "udp6") if ":" in source[0] else (socket.AF_INET, "udp")
    inode = socket_inodes(Path(f"/proc/net/{table}").read_text(), family).get((source[0], source[1]))
    if inode is None:
        return None
    target = f"socket:[{inode}]"
    for process in Path("/proc").iterdir():
        if not process.name.isdigit():
            continue
        try:
            for fd in (process / "fd").iterdir():
                try:
                    if os.readlink(fd) == target:
                        return int(process.name)
                except FileNotFoundError:
                    continue
        except FileNotFoundError:
            continue
    return None


def family_safety(cases: dict) -> bool:
    for scenario in ("a_only", "aaaa_only", "dual_stack", "nat64"):
        case = cases.get(scenario)
        if case is None or case["sender_instances"] != 1:
            return False
        paths = case["uplinks"]
        if len(paths) != 2 or any(path["address"] is None for path in paths):
            return False
        if len({path["node"] for path in paths}) != 1:
            return False
        addresses = [ipaddress.ip_address(path["address"]) for path in paths]
        families = {address.version for address in addresses}
        if scenario == "a_only" and families != {4}:
            return False
        if scenario == "aaaa_only" and families != {6}:
            return False
        if scenario == "dual_stack" and families != {4, 6}:
            return False
        if scenario == "nat64":
            synthesized = any(
                address.version == 6 and address in ipaddress.IPv6Network("64:ff9b::/96")
                for address in addresses
            )
            translated = any(packet["path"] == -1 for packet in case["packets"])
            if not synthesized or not translated:
                return False
    return True


def launch_command(sender: str, command: dict, variables: dict) -> list[str]:
    if sender != "ceraui-resolveSrtla":
        return argv(command, variables)
    module = Path(text(command["helper_module"])).resolve()
    if not module.is_file():
        raise PrerequisiteError(f"missing_ceraui_application_module:{module}")
    if "setup_file" not in command:
        raise PrerequisiteError("missing_ceraui_setup_file:setup_file config")
    setup_file = Path(text(command["setup_file"])).resolve()
    if not setup_file.is_file():
        raise PrerequisiteError(f"missing_ceraui_setup_file:{setup_file}")
    return [
        require_tool(text(command.get("bun", "bun"))),
        str(Path(__file__).with_name("ceraui-resolver-probe.mjs").resolve()),
        str(module), require_tool(text(command["sender_binary"])),
        str(variables["local_port"]), variables["hostname"],
        str(variables["receiver_port"]), variables["ips_file"],
    ]


def verdict(observations: list[dict], requested: list[str], missing: list[str]) -> JsonMap:
    senders = {}
    for sender in SENDERS:
        cases = {row["scenario"]: row for row in observations if row["sender"] == sender}
        control = cases.get("control")
        relay = cases.get("per_relay")
        stale = cases.get("stale_cache")
        full_relay = relay is not None and all(p["address"] is not None for p in relay["uplinks"])
        relay_addresses = {p["address"] for p in relay["uplinks"]} if full_relay else set()
        stale_nodes = {p["node"] for p in stale["uplinks"] if p["node"]} if stale else set()
        senders[sender] = {
            "resolution": classify(control) if control else "unknown",
            "per_relay_single_answer": full_relay and len(relay_addresses) == 1,
            "split_during_change": len(stale_nodes) > 1,
            "dual_stack_safe": family_safety(cases),
            "status": "OBSERVED" if cases else "UNVERIFIED",
            "reason": None if cases else f"missing_sender_command:{sender}",
            "cases": cases,
        }
    relay_union = {
        p["address"] for row in observations if row["scenario"] == "per_relay"
        for p in row["uplinks"] if p["address"] is not None
    }
    complete = set(requested) == set(SENDERS) and not missing
    per_relay = complete and all(s["per_relay_single_answer"] for s in senders.values()) and len(relay_union) == 1
    return {
        "scenario": "G5", "source": "live", "qualified": False,
        "status": "SKIP" if missing else "OBSERVED",
        "reason": ";".join(missing) if missing else None,
        "winner": "observed" if not missing else "insufficient",
        "complete": complete, "senders": senders,
        "control_split_detected": any(s["resolution"] == "per_network" for s in senders.values()),
        "per_relay_single_answer": per_relay,
        "split_during_change": any(s["split_during_change"] for s in senders.values()),
        "dual_stack_safe": complete and all(s["dual_stack_safe"] for s in senders.values()),
        "dual_stack_limit": "UDP destination gate only; no carrier ICMP/fragmentation/MTU qualification; absent/failing families stay unsafe",
        "moblin_mock_pin": MOBLIN_PIN, "observations": observations,
        "unverified_apps": {
            app: {"status": "UNVERIFIED", "reason": "physical application/device is not automated"}
            for app in ("IRL Pro", "Larix", "OBS SRTLA forks", "BELABOX")
        },
    }


@contextmanager
def namespace(pid: int):
    with Path("/proc/self/ns/net").open("rb") as original, Path(f"/proc/{pid}/ns/net").open("rb") as target:
        os.setns(target.fileno(), 0)
        try:
            yield
        finally:
            os.setns(original.fileno(), 0)


def ip(*arguments: str, pid: int | None = None) -> None:
    command = ["ip", *arguments]
    if pid is not None:
        command = ["nsenter", "--target", str(pid), "--net", *command]
    subprocess.run(command, check=True, capture_output=True, text=True, timeout=10)


class Lab:
    def __init__(self, directory: Path, processes: Processes, service_port: int) -> None:
        self.directory = directory
        self.processes = processes
        self.service_port = service_port
        self.resources = ExitStack()
        self.selector = self.resources.enter_context(selectors.DefaultSelector())
        self.queries: list[dict] = []
        self.destinations: list[dict] = []
        self.groups: set[bytes] = set()
        self.translations: dict[tuple, socket.socket] = {}
        self.exited: set[int] = set()
        self.control_replies: dict[int, bytes] = {}
        self.resolvers = [Resolver(index, "control") for index in range(2)]
        self.holders = []

    def setup(self) -> None:
        subprocess.run(["mount", "--make-rprivate", "/"], check=True)
        resolv = self.directory / "resolv.conf"
        resolv.write_text(f"nameserver {DNS4}\nnameserver {DNS6}\noptions attempts:1 timeout:1\n")
        nss = self.directory / "nsswitch.conf"
        nss.write_text("hosts: files dns\n")
        for source, target in ((resolv, Path("/etc/resolv.conf").resolve()), (nss, Path("/etc/nsswitch.conf").resolve())):
            subprocess.run(["mount", "--bind", str(source), str(target)], check=True)
        ip("link", "set", "lo", "up")
        Path("/proc/sys/net/ipv4/ip_local_port_range").write_text("43000 43999\n")
        for index in range(2):
            holder = self.processes.start(
                [sys.executable, str(Path(__file__).resolve()), "--hold-netns"],
                self.directory / f"netns-{index}.log", "NETNS_READY",
            )
            self.holders.append(holder)
            device, peer = f"uplink{index}", f"path{index}"
            prefix = f"10.{203 + index}.0"
            prefix6 = f"fd73:{index + 1}"
            ip("link", "add", device, "type", "veth", "peer", "name", peer)
            ip("link", "set", peer, "netns", str(holder.pid))
            ip("addr", "add", prefix + ".2/24", "dev", device)
            ip("-6", "addr", "add", prefix6 + "::2/64", "dev", device, "nodad")
            ip("link", "set", device, "up")
            ip("link", "set", "lo", "up", pid=holder.pid)
            ip("addr", "add", prefix + ".1/24", "dev", peer, pid=holder.pid)
            ip("-6", "addr", "add", prefix6 + "::1/64", "dev", peer, "nodad", pid=holder.pid)
            ip("link", "set", peer, "up", pid=holder.pid)
            ip("addr", "add", DNS4 + "/32", "dev", "lo", pid=holder.pid)
            ip("-6", "addr", "add", DNS6 + "/128", "dev", "lo", "nodad", pid=holder.pid)
            for node in NODES.values():
                ip("addr", "add", node["a"] + "/32", "dev", "lo", pid=holder.pid)
                ip("-6", "addr", "add", node["aaaa"] + "/128", "dev", "lo", "nodad", pid=holder.pid)
            ip("-6", "addr", "add", "64:ff9b::c612:1/128", "dev", "lo", "nodad", pid=holder.pid)
            table = str(100 + index)
            ip("route", "add", prefix + ".0/24", "dev", device, "table", table)
            ip("route", "add", "default", "via", prefix + ".1", "dev", device, "table", table)
            ip("rule", "add", "from", prefix + ".2", "table", table)
            ip("-6", "route", "add", prefix6 + "::/64", "dev", device, "table", table)
            ip("-6", "route", "add", "default", "via", prefix6 + "::1", "dev", device, "table", table)
            ip("-6", "rule", "add", "from", prefix6 + "::2", "table", table)
            if index == 0:
                ip("route", "add", "default", "via", prefix + ".1", "dev", device)
                ip("-6", "route", "add", "default", "via", prefix6 + "::1", "dev", device)
            with namespace(holder.pid):
                self.listen(index, DNS4, 53, "dns", None)
                self.listen(index, DNS6, 53, "dns", None)
                for node, addresses in NODES.items():
                    for address in addresses.values():
                        self.listen(index, address, self.service_port, "srtla", node)
                self.listen(index, "64:ff9b::c612:1", self.service_port, "nat64", "g1-lab")
        (self.directory / "topology.json").write_text(json.dumps({
            "sender_namespace": os.readlink("/proc/self/ns/net"),
            "paths": [{"pid": p.pid, "namespace": os.readlink(f"/proc/{p.pid}/ns/net")} for p in self.holders],
            "dns_address": DNS4, "nodes": NODES,
        }, indent=2) + "\n")

    def listen(self, path: int, address: str, service_port: int, kind: str, node: str | None) -> None:
        family = socket.AF_INET6 if ":" in address else socket.AF_INET
        sock = self.resources.enter_context(socket.socket(family, socket.SOCK_DGRAM))
        if family == socket.AF_INET6:
            sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        sock.bind((address, service_port))
        sock.setblocking(False)
        self.selector.register(sock, selectors.EVENT_READ, (path, address, kind, node))

    def receive(self, timeout: float) -> int:
        events = self.selector.select(timeout)
        for key, _ in events:
            path, address, kind, node = key.data
            if kind == "process-exit":
                self.exited.add(node)
                continue
            packet, source = key.fileobj.recvfrom(65535)
            if kind == "control-reply":
                self.control_replies[node] = packet
                continue
            if kind == "nat64-reply":
                # The IPv4 reply crosses back through the same per-client mapping.
                node[0].sendto(packet, node[1])
                continue
            if kind == "dns":
                try:
                    response, record = self.resolvers[path].answer(packet, time.monotonic())
                except (ValueError, IndexError, UnicodeError):
                    continue
                record.update(source=list(source), timestamp=time.monotonic())
                self.queries.append(record)
                key.fileobj.sendto(response, source)
            else:
                if len(packet) < 2:
                    continue
                packet_type = struct.unpack("!H", packet[:2])[0]
                self.destinations.append({
                    "path": -1 if source[0] == "127.0.0.1" else path,
                    "address": address, "node": node,
                    "socket_owner_pid": socket_owner(source),
                    "source": list(source), "packet_type": packet_type, "timestamp": time.monotonic(),
                })
                if kind == "nat64":
                    mapping_key = (path, source)
                    if mapping_key not in self.translations:
                        with namespace(self.holders[path].pid):
                            bridge = self.resources.enter_context(socket.socket(socket.AF_INET, socket.SOCK_DGRAM))
                            bridge.bind(("127.0.0.1", 0))
                            bridge.connect((NODES["g1-lab"]["a"], self.service_port))
                            bridge.setblocking(False)
                        self.translations[mapping_key] = bridge
                        self.selector.register(bridge, selectors.EVENT_READ, (path, address, "nat64-reply", (key.fileobj, source)))
                    self.translations[mapping_key].send(packet)
                    continue
                response = None
                if packet_type == 0x9200 and len(packet) == 258:
                    self.groups.add(packet[2:])
                    response = b"\x92\x01" + packet[2:]
                elif packet_type == 0x9201 and len(packet) == 258:
                    response = b"\x92\x02" if packet[2:] in self.groups else b"\x92\x11"
                elif packet_type == 0x9000:
                    response = packet
                if response:
                    key.fileobj.sendto(response, source)
        return len(events)

    def prime_stale(self, hostname: str) -> None:
        query = b"\x00\x01\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" + dns_name(hostname) + b"\x00\x01\x00\x01"
        with ExitStack() as stack:
            sockets = []
            for index in range(2):
                sock = stack.enter_context(socket.socket(socket.AF_INET, socket.SOCK_DGRAM))
                sock.bind((f"10.{203 + index}.0.2", 0))
                sock.settimeout(5)
                sockets.append(sock)
                sock.sendto(query, (DNS4, 53))
            # Service the exact priming requests before changing authority.
            before = len(self.queries)
            deadline = time.monotonic() + 5
            while len(self.queries) < before + 2:
                if time.monotonic() >= deadline:
                    raise RuntimeError("stale_cache_priming_timeout")
                self.receive(max(0, deadline - time.monotonic()))
            for sock in sockets:
                sock.recvfrom(4096)
        for resolver in self.resolvers:
            resolver.authority = "g2-lab"
        self.resolvers[1].cache.clear()

    def isolation_controls(self) -> list[dict]:
        """Calibrate paths with one known process, never label it a product sender."""
        results = []
        for scenario, once in (("control", True), ("control", False), ("stale_cache", False), ("nat64", False)):
            while self.receive(0):
                pass
            hostname = "geo.ingest.test" if scenario == "control" else "r-abcdefghij.ingest.test"
            self.resolvers = [Resolver(index, scenario) for index in range(2)]
            if scenario == "stale_cache":
                self.prime_stale(hostname)
            query_start = len(self.queries)
            destination_start = len(self.destinations)
            addresses = []
            with ExitStack() as stack:
                for index in range(2):
                    ipv6 = scenario == "nat64" and index == 1
                    family = socket.AF_INET6 if ipv6 else socket.AF_INET
                    source = f"fd73:{index + 1}::2" if ipv6 else f"10.{203 + index}.0.2"
                    if not once or index == 0:
                        resolver_socket = stack.enter_context(socket.socket(family, socket.SOCK_DGRAM))
                        resolver_socket.bind((source, 0))
                        resolver_socket.settimeout(5)
                        query = (b"\x00\x01\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
                                 + dns_name(hostname) + struct.pack("!HH", 28 if ipv6 else 1, 1))
                        resolver_socket.sendto(query, (DNS6 if ipv6 else DNS4, 53))
                        self.receive(5)
                        response = resolver_socket.recvfrom(4096)[0]
                        address = str(ipaddress.ip_address(response[-16:] if ipv6 else response[-4:]))
                    addresses.append(address)
                    uplink = stack.enter_context(socket.socket(family, socket.SOCK_DGRAM))
                    uplink.bind((source, 0))
                    uplink.setblocking(False)
                    descriptor = uplink.fileno()
                    self.selector.register(uplink, selectors.EVENT_READ, (-1, "", "control-reply", descriptor))
                    stack.callback(self.selector.unregister, uplink)
                    stack.callback(self.control_replies.pop, descriptor, None)
                    payload = b"\x90\x00" + bytes(8)
                    uplink.sendto(payload, (address, self.service_port))
                    deadline = time.monotonic() + 5
                    while descriptor not in self.control_replies:
                        if time.monotonic() >= deadline:
                            raise RuntimeError(f"isolation_roundtrip_timeout:{scenario}:{index}")
                        self.receive(max(0, deadline - time.monotonic()))
                    if self.control_replies[descriptor] != payload:
                        raise RuntimeError(f"isolation_roundtrip_mismatch:{scenario}:{index}")
            captured = self.destinations[destination_start:]
            owners = {packet["socket_owner_pid"] for packet in captured if packet["path"] >= 0}
            observation = {
                "sender_instances": len(owners) if None not in owners else 0,
                "resolver_queries": [q["resolver"] for q in self.queries[query_start:]],
                "uplinks": [{"address": address} for address in addresses],
                "packets": captured,
            }
            if scenario == "control":
                expected = "resolve_once" if once else "per_network"
                actual = classify(observation)
            elif scenario == "stale_cache":
                expected = "stale_cache_split"
                actual = expected if len({p["node"] for p in captured}) == 2 else "FAIL"
            else:
                expected = "nat64_roundtrip"
                actual = expected if any(p["path"] == -1 for p in captured) else "FAIL"
            if actual != expected or not {0, 1} <= {p["path"] for p in captured}:
                raise RuntimeError(f"isolation_control_failed:{expected}:{actual}")
            results.append({"expected": expected, "actual": actual, "observation": observation})
        return results

    def observe(self, sender: str, command: dict, scenario: str, timeout: float) -> dict:
        # The previous process has been reaped. Drain its queued datagrams before
        # opening a new observation, so late registration cannot become evidence.
        while self.receive(0):
            pass
        hostname = "geo.ingest.test" if scenario == "control" else "r-abcdefghij.ingest.test"
        self.resolvers = [Resolver(index, scenario) for index in range(2)]
        if scenario == "stale_cache":
            self.prime_stale(hostname)
        query_start, destination_start = len(self.queries), len(self.destinations)
        ips = self.directory / f"{sender}-{scenario}-ips.txt"
        addresses = ["10.203.0.2", "10.204.0.2"]
        if scenario == "aaaa_only":
            addresses = ["fd73:1::2", "fd73:2::2"]
        elif scenario in ("dual_stack", "nat64"):
            addresses[1] = "fd73:2::2"
        ips.write_text("\n".join(addresses) + "\n")
        variables = {
            "hostname": hostname, "receiver_port": self.service_port, "local_port": 43061,
            "ips_file": str(ips), "ip0": addresses[0], "ip1": addresses[1],
        }
        log = self.directory / f"{sender}-{scenario}.log"
        application_cwd = None
        application_env = None
        if sender == "ceraui-resolveSrtla":
            application_cwd = self.directory / f"{sender}-{scenario}-application"
            application_cwd.mkdir()
            (application_cwd / "setup.json").write_bytes(Path(text(command["setup_file"])).read_bytes())
            application_env = {
                **os.environ, "NODE_ENV": "production", "MOCK_MODE": "false",
                "CERALIVE_DEVICE_TYPE": "emulated", "HOME": str(application_cwd),
            }
        with Processes() as process, ExitStack() as lifetime:
            child = process.start(
                launch_command(sender, command, variables), log,
                cwd=application_cwd, env=application_env,
            )
            exited = lifetime.enter_context(os.fdopen(os.pidfd_open(child.pid), "rb"))
            self.selector.register(exited, selectors.EVENT_READ, (-1, "", "process-exit", child.pid))
            lifetime.callback(self.selector.unregister, exited)
            lifetime.callback(self.exited.discard, child.pid)
            started = time.monotonic()
            deadline = started + timeout
            # The capture sockets exist before the single sender is launched.
            # Finish on both observed paths, process exit, or the named deadline.
            while time.monotonic() < deadline:
                self.receive(max(0, deadline - time.monotonic()))
                seen = {d["path"] for d in self.destinations[destination_start:]}
                if {0, 1} <= seen or child.pid in self.exited:
                    self.receive(0)
                    break
            exit_code = child.poll()
            observed = self.destinations[destination_start:]
            owners = {p["socket_owner_pid"] for p in observed if p["path"] >= 0}
            uplinks = []
            for index in range(2):
                captured = [d for d in observed if d["path"] == index]
                selected_addresses = {d["address"] for d in captured}
                selected = captured[-1] if len(selected_addresses) == 1 else {}
                uplinks.append({
                    "namespace": f"path-{index}", "resolver": f"resolver-{index}",
                    "address": selected.get("address"), "node": selected.get("node"),
                    "reason": None if selected else "absent_or_ambiguous_destination",
                    "addresses": sorted(selected_addresses),
                    "cname_chain": next((
                        q["cname_chain"] for q in self.queries[query_start:]
                        if q["answer"] == selected.get("address")
                    ), []),
                })
            queries = self.queries[query_start:]
            capture_duration = time.monotonic() - started
            process.close()
            application_results = []
            for line in log.read_text().splitlines():
                if line.startswith("{"):
                    try:
                        event = json.loads(line)
                    except ValueError:
                        continue
                    if "phase" in event or "prerequisite" in event:
                        application_results.append(event)
            return {
                "sender": sender, "scenario": scenario, "hostname": hostname,
                "sender_instances": len(owners) if None not in owners else 0,
                "observed_socket_owner_pids": sorted(pid for pid in owners if pid is not None),
                "sender_pid": child.pid, "argv": child.args,
                "boundary": command["boundary"], "source_sha": command.get("source_sha"),
                "application_results": application_results,
                "duration_s": capture_duration, "exit_code_before_teardown": exit_code,
                "resolver_queries": [q["resolver"] for q in queries if q["hostname"] == hostname],
                "queries": queries, "uplinks": uplinks, "packets": observed,
            }


def worker(config: JsonMap, directory: Path) -> JsonMap:
    commands = mapping(config["senders"])
    requested = [text(value) for value in rows(config.get("requested", list(SENDERS)))]
    if len(set(requested)) != len(requested) or not set(requested) <= set(SENDERS):
        raise ValueError("unknown or duplicate requested sender")
    missing = [
        text(reason) for reason in config.get("prerequisite_reasons", [])
        if text(reason).split(":")[0] in requested
    ]
    missing.extend(f"missing_sender_command:{sender}" for sender in requested if sender not in commands)
    observations = []
    with Processes() as processes:
        lab = Lab(directory, processes, port(int(config.get("receiver_port", 43060))))
        try:
            lab.setup()
            controls = lab.isolation_controls()
            for sender in requested:
                if sender not in commands:
                    continue
                command = mapping(commands[sender])
                expected = {"moblin-mock": "sequential-rebind", "ceraui-resolveSrtla": "application-cache"}
                if command.get("boundary") != expected.get(sender, "bonded-process"):
                    raise ValueError(f"incorrect_execution_boundary:{sender}")
                for scenario in SCENARIOS:
                    observation = lab.observe(
                        sender, command, scenario, number(config.get("timeout_s", 8), positive=True),
                    )
                    observations.append(observation)
                    prerequisites = [
                        event["prerequisite"] for event in observation["application_results"]
                        if "prerequisite" in event
                    ]
                    if prerequisites:
                        missing.extend(f"{sender}:{reason}" for reason in prerequisites)
                        break
        finally:
            lab.resources.close()
    result = verdict(observations, requested, missing)
    result["isolation_controls"] = controls
    (directory / "capture.json").write_text(json.dumps({
        "queries": lab.queries, "destinations": lab.destinations,
    }, indent=2) + "\n")
    return result


def campaign(config: JsonMap, directory: Path) -> JsonMap:
    for executable in ("unshare", "ip", "nsenter", "mount"):
        require_tool(executable)
    if "senders" not in config:
        raise PrerequisiteError("missing_g5_config:senders")
    commands = mapping(config["senders"])
    if not set(commands) <= set(SENDERS):
        raise ValueError("unknown sender command")
    if not all(hasattr(os, name) for name in ("setns", "unshare", "pidfd_open")):
        raise PrerequisiteError("missing_python_namespace_api:Python>=3.12")
    probe = subprocess.run(
        ["unshare", "--user", "--map-root-user", "--net", "--mount", "sh", "-ec",
         "mount --make-rprivate /; ip link add probe0 type veth peer name probe1; ip link del probe0"],
        capture_output=True, text=True, timeout=10, check=False,
    )
    if probe.returncode:
        raise PrerequisiteError("user_network_mount_namespaces_denied:" + probe.stderr.strip())
    available = {}
    missing = []
    for sender, raw in commands.items():
        try:
            launch_command(sender, mapping(raw), {
                "hostname": "r-abcdefghij.ingest.test", "receiver_port": 43060,
                "local_port": 43061, "ips_file": "ips.txt", "ip0": "10.203.0.2", "ip1": "10.204.0.2",
            })
            available[sender] = raw
        except PrerequisiteError as error:
            missing.append(f"{sender}:{error}")
    config = {**config, "senders": available, "prerequisite_reasons": missing}
    source = directory / "config.json"
    source.write_text(json.dumps(config) + "\n")
    completed = subprocess.run([
        "unshare", "--user", "--map-root-user", "--net", "--mount",
        "--pid", "--fork", "--mount-proc", "--kill-child", sys.executable, str(Path(__file__).resolve()),
        "--worker", str(source), str(directory),
    ], capture_output=True, text=True, check=False, timeout=1800)
    (directory / "worker.log").write_text(completed.stderr)
    if completed.returncode:
        raise RuntimeError(f"g5_worker_failed:{completed.returncode}:{completed.stderr}")
    return mapping(json.loads(completed.stdout))


if __name__ == "__main__":
    if sys.argv[1:] == ["--hold-netns"]:
        os.unshare(os.CLONE_NEWNET)
        print("NETNS_READY", flush=True)
        signal.pause()
    elif len(sys.argv) == 4 and sys.argv[1] == "--worker":
        try:
            print(json.dumps(worker(mapping(json.loads(Path(sys.argv[2]).read_text())), Path(sys.argv[3]))))
        except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
            print(f"G5: {error}", file=sys.stderr)
            raise SystemExit(2) from error
    else:
        raise SystemExit("internal worker entry point")

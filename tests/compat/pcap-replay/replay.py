#!/usr/bin/env python3
"""
replay.py — dependency-free SRTLA pcap replay engine.

Two modes, one file (stdlib only — no scapy / tcpreplay needed):

  replay.py replay <pcap> --host H --port P   Replay a captured srtla_send
                                              session against a *live* srtla_rec.
  replay.py sink --port D --count-file F       Trivial UDP datagram counter used
                                              as the downstream "SRT server" so
                                              we can measure packets actually
                                              forwarded by srtla_rec.

Why a custom replayer instead of `tcpreplay`?

  SRTLA registration is a stateful two-phase handshake. The group id is
  `sender_half(128B) || receiver_random(128B)` and the receiver matches the
  full 256 bytes (src/connection/connection_registry.cpp:find_group_by_id).
  A blind packet replay would carry the *old* receiver nonce captured in the
  pcap, so a fresh srtla_rec answers REG2 with a *different* nonce and every
  replayed REG2 is rejected as "No group found".

  This replayer is therefore handshake-aware: it sends the captured REG1, reads
  the live receiver's REG2 reply, learns the new group id, and rewrites the id
  field of every outgoing REG2 before sending it. Everything else (SRT media,
  keepalives) is replayed verbatim at the recorded inter-packet timing.

Only the sender->receiver direction (UDP datagrams whose destination port is
the receiver port) is replayed; the receiver's own captured replies are dropped.

Exit codes: 0 ok, 2 usage / parse error.
"""

import argparse
import socket
import struct
import sys
import time

# SRTLA wire constants — mirror of src/common.h.
SRTLA_TYPE_KEEPALIVE = 0x9000
SRTLA_TYPE_REG1 = 0x9200
SRTLA_TYPE_REG2 = 0x9201
SRTLA_TYPE_REG3 = 0x9202
SRTLA_ID_LEN = 256
SRTLA_TYPE_REG1_LEN = 2 + SRTLA_ID_LEN
SRTLA_TYPE_REG2_LEN = 2 + SRTLA_ID_LEN

# pcap global-header magics (libpcap classic, both endiannesses + nanosecond).
PCAP_MAGIC_USEC_LE = 0xA1B2C3D4
PCAP_MAGIC_NSEC_LE = 0xA1B23C4D

# Link-layer types we know how to strip down to an IP packet.
DLT_NULL = 0          # BSD/Linux loopback: 4-byte address-family header
DLT_EN10MB = 1        # Ethernet: 14-byte header
DLT_RAW_A = 12        # raw IP
DLT_RAW_B = 101       # raw IP (alt)
DLT_LINUX_SLL = 113   # Linux "cooked" v1: 16-byte header
DLT_LINUX_SLL2 = 276  # Linux "cooked" v2: 20-byte header


def _srtla_type(payload: bytes) -> int:
    if len(payload) < 2:
        return -1
    return struct.unpack(">H", payload[:2])[0]


# --------------------------------------------------------------------------- #
# pcap parsing                                                                 #
# --------------------------------------------------------------------------- #
def _iter_records(data: bytes):
    """Yield (ts_float, link_type, packet_bytes) for each pcap record."""
    if len(data) < 24:
        raise ValueError("file too short to be a pcap")
    magic = struct.unpack("<I", data[:4])[0]
    if magic in (PCAP_MAGIC_USEC_LE, PCAP_MAGIC_NSEC_LE):
        endian = "<"
        nsec = magic == PCAP_MAGIC_NSEC_LE
    else:
        magic_be = struct.unpack(">I", data[:4])[0]
        if magic_be in (PCAP_MAGIC_USEC_LE, PCAP_MAGIC_NSEC_LE):
            endian = ">"
            nsec = magic_be == PCAP_MAGIC_NSEC_LE
        else:
            raise ValueError(
                "unrecognised magic 0x%08x — not a classic pcap "
                "(pcapng is unsupported; capture with `tcpdump -w`)" % magic
            )
    link_type = struct.unpack(endian + "I", data[20:24])[0]
    off = 24
    rec_hdr = struct.Struct(endian + "IIII")
    divisor = 1_000_000_000.0 if nsec else 1_000_000.0
    while off + 16 <= len(data):
        ts_sec, ts_frac, incl_len, _orig_len = rec_hdr.unpack_from(data, off)
        off += 16
        if incl_len == 0 or off + incl_len > len(data):
            break
        pkt = data[off:off + incl_len]
        off += incl_len
        yield ts_sec + ts_frac / divisor, link_type, pkt


def _strip_link(link_type: int, pkt: bytes):
    """Return (ip_proto_payload, l4_is_ipv4) after removing the link header."""
    if link_type == DLT_NULL:
        if len(pkt) < 4:
            return None
        return pkt[4:]
    if link_type == DLT_EN10MB:
        if len(pkt) < 14:
            return None
        ethertype = struct.unpack(">H", pkt[12:14])[0]
        if ethertype == 0x8100 and len(pkt) >= 18:  # 802.1Q VLAN tag
            return pkt[18:]
        return pkt[14:]
    if link_type in (DLT_RAW_A, DLT_RAW_B):
        return pkt
    if link_type == DLT_LINUX_SLL:
        return pkt[16:] if len(pkt) >= 16 else None
    if link_type == DLT_LINUX_SLL2:
        return pkt[20:] if len(pkt) >= 20 else None
    return None


def _udp_from_ip(ipdata: bytes):
    """Return (dst_port, udp_payload) for a UDP datagram, else None."""
    if len(ipdata) < 1:
        return None
    version = ipdata[0] >> 4
    if version == 4:
        if len(ipdata) < 20:
            return None
        ihl = (ipdata[0] & 0x0F) * 4
        if ipdata[9] != 17 or len(ipdata) < ihl + 8:  # proto 17 == UDP
            return None
        l4 = ipdata[ihl:]
    elif version == 6:
        if len(ipdata) < 40 or ipdata[6] != 17:  # next-header 17 == UDP
            return None
        l4 = ipdata[40:]
    else:
        return None
    if len(l4) < 8:
        return None
    dst_port = struct.unpack(">H", l4[2:4])[0]
    udp_len = struct.unpack(">H", l4[4:6])[0]
    payload = l4[8:udp_len] if 8 <= udp_len <= len(l4) else l4[8:]
    return dst_port, payload


def _all_udp(data: bytes):
    """Ordered [(ts, dst_port, payload)] for every UDP datagram in the pcap."""
    out = []
    for ts, link_type, pkt in _iter_records(data):
        ipdata = _strip_link(link_type, pkt)
        if ipdata is None:
            continue
        udp = _udp_from_ip(ipdata)
        if udp is None:
            continue
        dst_port, payload = udp
        if payload:
            out.append((ts, dst_port, payload))
    return out


def detect_capture_port(udp_packets):
    """Infer the SRTLA receiver port used at capture time.

    The receiver port is whichever dst port carries a REG1 (0x9200); failing
    that (capture started mid-session), the busiest dst port. Decoupling the
    captured port from the live --port lets a fixture taken on any port be
    replayed against our test receiver on a fixed local port.
    """
    from collections import Counter
    counts = Counter()
    for _ts, dst_port, payload in udp_packets:
        counts[dst_port] += 1
        if _srtla_type(payload) == SRTLA_TYPE_REG1 \
                and len(payload) == SRTLA_TYPE_REG1_LEN:
            return dst_port
    return counts.most_common(1)[0][0] if counts else None


def extract_sender_packets(path: str, capture_port=None):
    """(capture_port, [(ts, payload)]) for datagrams TO the receiver port."""
    with open(path, "rb") as fh:
        data = fh.read()
    udp_packets = _all_udp(data)
    if capture_port is None:
        capture_port = detect_capture_port(udp_packets)
    out = [(ts, payload) for ts, dst_port, payload in udp_packets
           if dst_port == capture_port]
    return capture_port, out


# --------------------------------------------------------------------------- #
# replay mode                                                                  #
# --------------------------------------------------------------------------- #
def do_replay(args) -> int:
    capture_port, packets = extract_sender_packets(args.pcap, args.capture_port)
    if not packets:
        print("replay: no sender->receiver UDP packets found (capture_port=%s) "
              "in %s" % (capture_port, args.pcap), file=sys.stderr)
        return 2

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.connect((args.host, args.port))

    group_id = None          # live receiver's REG2 id, learned during handshake
    sent_data = 0
    sent_total = 0
    reg_done = False
    base_ts = packets[0][0]
    start_wall = time.monotonic()

    for idx, (ts, payload) in enumerate(packets):
        # Honour recorded inter-packet timing, scaled by --speed and capped so a
        # gap in the capture never stalls the self-test.
        if args.speed > 0:
            target = (ts - base_ts) / args.speed
            delay = target - (time.monotonic() - start_wall)
            if delay > 0:
                time.sleep(min(delay, args.max_gap))

        ptype = _srtla_type(payload)

        if ptype == SRTLA_TYPE_REG1 and len(payload) == SRTLA_TYPE_REG1_LEN:
            sock.send(payload)
            sent_total += 1
            # Wait for the receiver's REG2 to learn the new group id.
            sock.settimeout(args.reg_timeout)
            deadline = time.monotonic() + args.reg_timeout
            while time.monotonic() < deadline:
                try:
                    reply = sock.recv(2048)
                except socket.timeout:
                    break
                if _srtla_type(reply) == SRTLA_TYPE_REG2 \
                        and len(reply) >= 2 + SRTLA_ID_LEN:
                    group_id = reply[2:2 + SRTLA_ID_LEN]
                    break
            sock.setblocking(True)
            continue

        if ptype == SRTLA_TYPE_REG2 and len(payload) == SRTLA_TYPE_REG2_LEN:
            if group_id is not None:
                payload = payload[:2] + group_id  # rewrite id with live nonce
            sock.send(payload)
            sent_total += 1
            # Drain a possible REG3 confirmation (non-blocking).
            sock.settimeout(0.05)
            try:
                ack = sock.recv(2048)
                if _srtla_type(ack) == SRTLA_TYPE_REG3:
                    reg_done = True
            except socket.timeout:
                pass
            sock.setblocking(True)
            continue

        # Media / keepalive / ack — replay verbatim.
        sock.send(payload)
        sent_total += 1
        if ptype != SRTLA_TYPE_KEEPALIVE and len(payload) >= 16:
            sent_data += 1

    sock.close()
    print("replay: capture_port=%d sent %d packets (%d data) to %s:%d; "
          "group_id=%s reg3=%s"
          % (capture_port, sent_total, sent_data, args.host, args.port,
             "learned" if group_id else "none", reg_done))
    return 0


# --------------------------------------------------------------------------- #
# sink mode (downstream UDP counter)                                           #
# --------------------------------------------------------------------------- #
def do_sink(args) -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((args.host, args.port))
    sock.settimeout(args.idle)

    state = {"count": 0}

    def flush_and_exit(*_):
        # Persist the count on SIGTERM too: the orchestrator stops us that way.
        with open(args.count_file, "w") as fh:
            fh.write(str(state["count"]) + "\n")
        print("sink: received %d datagrams on %s:%d"
              % (state["count"], args.host, args.port))
        sys.exit(0)

    import signal
    signal.signal(signal.SIGTERM, flush_and_exit)
    signal.signal(signal.SIGINT, flush_and_exit)

    deadline = time.monotonic() + args.duration
    while time.monotonic() < deadline:
        try:
            data = sock.recv(65535)
        except socket.timeout:
            break  # idle for --idle seconds → assume stream finished
        if data:
            state["count"] += 1
    sock.close()
    flush_and_exit()


def main(argv) -> int:
    parser = argparse.ArgumentParser(description="SRTLA pcap replay engine")
    sub = parser.add_subparsers(dest="mode", required=True)

    rp = sub.add_parser("replay", help="replay a pcap against a live srtla_rec")
    rp.add_argument("pcap")
    rp.add_argument("--host", default="127.0.0.1")
    rp.add_argument("--port", type=int, default=5000,
                    help="live receiver srtla_port to replay TO")
    rp.add_argument("--capture-port", type=int, default=None,
                    help="srtla port as seen in the pcap (default: autodetect)")
    rp.add_argument("--speed", type=float, default=4.0,
                    help="timing multiplier (>1 = faster; 0 = no pacing)")
    rp.add_argument("--max-gap", type=float, default=0.5,
                    help="cap on any single inter-packet sleep (s)")
    rp.add_argument("--reg-timeout", type=float, default=2.0,
                    help="seconds to wait for the receiver's REG2 reply")
    rp.set_defaults(func=do_replay)

    sk = sub.add_parser("sink", help="downstream UDP datagram counter")
    sk.add_argument("--host", default="127.0.0.1")
    sk.add_argument("--port", type=int, required=True)
    sk.add_argument("--count-file", required=True)
    sk.add_argument("--duration", type=float, default=120.0,
                    help="hard cap on total run time (s)")
    sk.add_argument("--idle", type=float, default=5.0,
                    help="stop after this many idle seconds (s)")
    sk.set_defaults(func=do_sink)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except (ValueError, OSError) as exc:
        print("replay.py: %s" % exc, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

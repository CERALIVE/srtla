#!/usr/bin/env python3
"""Moblin SRTLA conformance mock sender.

A minimal, source-faithful re-implementation of the SRTLA *client* (sender) wire
behaviour of Moblin (https://github.com/eerimoq/moblin), pinned at
0ae5294950166978064840bc874bfed3a8cf03a4. Every wire behaviour below is keyed to
a numbered entry in BEHAVIOR.md ([B1]..[B7]); do not change one without updating
the other (see MUST-NOT in the task: the mock may not silently drift from
BEHAVIOR.md).

This is NOT a Swift port and NOT the Moblin app. It re-creates only the SRTLA
layer so our `srtla_rec` can be exercised against Moblin's exact handshake,
keepalive, reconnect and network-path-change semantics.

Topology (mirrors srtla_send's role as the SRTLA layer between an SRT caller and
the SRTLA receiver):

    SRT caller (ffmpeg) --UDP--> [local listen sock]  MOCK  [uplink sock] --UDP--> srtla_rec
                        <--UDP--                                          <--UDP--

SRTLA data packets are raw SRT packets; only SRTLA control packets (REG*, ACK,
KEEPALIVE in the 0x9000-0x9212 range) carry SRTLA headers. The mock relays SRT
traffic transparently and speaks the SRTLA control protocol itself.
"""

from __future__ import annotations

import argparse
import os
import select
import signal
import socket
import struct
import sys
import time

# --- SRTLA / SRT wire constants -------------------------------------------- #
# Moblin: SrtlaPacketType (Common/Srtla.swift:7-16) OR'd with the SRT control
# bit 0x8000 (Common/Srt.swift:3, :18-21). The values below are the on-the-wire
# (post-OR) 16-bit big-endian type fields.
SRTLA_KEEPALIVE = 0x9000  # [B2]
SRTLA_ACK = 0x9100
SRTLA_REG1 = 0x9200  # create group
SRTLA_REG2 = 0x9201  # register connection / probe / reg2 reply
SRTLA_REG3 = 0x9202  # connection registered
SRTLA_REG_ERR = 0x9210
SRTLA_REG_NGP = 0x9211  # no group -> create one
SRTLA_REG_NAK = 0x9212

SRTLA_ID_LEN = 256  # Moblin: Data.random(length: 256) (RemoteConnection.swift:198,213)
REG_LEN = 2 + SRTLA_ID_LEN  # 258: type + 256-byte id
REG3_LEN = 2

# Moblin reconnect/keepalive timing (RemoteConnection.swift:309, :473-478). [B6]
CONNECT_TIMEOUT_S = 5.0
KEEPALIVE_PERIOD_S = 1.0
RX_WATCHDOG_S = 5.0

RECV_BUF = 2048


def now() -> float:
    return time.monotonic()


def u16be(buf: bytes) -> int:
    return (buf[0] << 8) | buf[1] if len(buf) >= 2 else 0


def is_srt_data_packet(buf: bytes) -> bool:
    # Moblin: isSrtDataPacket -> (packet[0] & 0x80) == 0 (Common/Srt.swift:18-20).
    return len(buf) >= 1 and (buf[0] & 0x80) == 0


class Uplink:
    """One SRTLA uplink: a UDP socket bound to a source IP, talking to srtla_rec.

    Models a Moblin RemoteConnection's socket. The source-IP bind mirrors
    Moblin pinning a connection to a network interface via
    `params.requiredInterface` (RemoteConnection.swift:137-144). [B4]
    """

    def __init__(self, bind_ip: str, dst: tuple[str, int]):
        self.bind_ip = bind_ip
        self.dst = dst
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind((bind_ip, 0))
        self.sock.connect(dst)  # fixes the 4-tuple so recv only sees srtla_rec
        self.sock.setblocking(False)
        # group id this uplink registered with (the receiver's full 256-byte id)
        self.group_id: bytes | None = None

    def fileno(self) -> int:
        return self.sock.fileno()

    def send(self, data: bytes) -> None:
        try:
            self.sock.send(data)
        except OSError:
            pass

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


class MoblinMock:
    # Handshake states, named after Moblin's RemoteConnection.State /
    # SrtlaClient.State (RemoteConnection.swift:10-16, SrtlaClient.swift:15-23).
    CONNECTING = "connecting"
    WAIT_PROBE = "wait_probe"        # sent REG2 probe, expect REG_NGP   [B1]
    WAIT_GROUP_ID = "wait_group_id"  # sent REG1, expect REG2            [B1]
    WAIT_REGISTERED = "wait_reg"     # sent REG2(real id), expect REG3   [B1]
    REGISTERED = "registered"

    def __init__(self, args: argparse.Namespace):
        self.dst = (args.receiver_host, args.receiver_port)
        self.local_addr = ("127.0.0.1", args.local_srt_port)
        self.bind_ip = args.bind_ip
        self.ip_change_to = args.ip_change_to
        self.ip_change_at = args.ip_change_at_sec  # seconds after register, or None

        # Local UDP listener for the SRT caller (ffmpeg). Moblin "official" mode
        # uses a local UDP listener too (LocalListener.swift, SrtlaClient.swift:373-382).
        self.local = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.local.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.local.bind(self.local_addr)
        self.local.setblocking(False)
        self.local_peer: tuple[str, int] | None = None

        self.uplink = Uplink(self.bind_ip, self.dst)
        self.pending_uplink: Uplink | None = None  # new uplink during IP change

        self.state = self.CONNECTING
        self.group_id: bytes | None = None  # full receiver group id once known
        self.start_ms = time.monotonic()
        self.connect_started = now()
        self.registered_at: float | None = None
        self.next_keepalive = 0.0
        self.last_rx = now()
        self.ip_changed = False
        self.stop = False

        signal.signal(signal.SIGTERM, self._on_signal)
        signal.signal(signal.SIGINT, self._on_signal)

    def _on_signal(self, *_):
        self.stop = True

    def log(self, msg: str) -> None:
        sys.stderr.write(f"moblin-mock: {msg}\n")
        sys.stderr.flush()

    # --- packet builders (Common/Srtla.swift:18-21: type | 0x8000) ----------- #
    @staticmethod
    def _reg_packet(type_field: int, group_id: bytes) -> bytes:
        return struct.pack(">H", type_field) + group_id

    def _keepalive_packet(self) -> bytes:
        # [B2] 10 bytes: 0x9000 + 8-byte BE ms since base time
        # (RemoteConnection.swift:408-416). NEVER the 38-byte extended variant.
        ms = int((time.monotonic() - self.start_ms) * 1000.0)
        return struct.pack(">H", SRTLA_KEEPALIVE) + struct.pack(">q", ms)

    # --- handshake actions --------------------------------------------------- #
    def send_probe(self, uplink: Uplink) -> None:
        # [B1] Moblin probes with a REG2 carrying a random group id
        # (RemoteConnection.swift:197-200, probe()). The receiver has no such
        # group and replies REG_NGP.
        uplink.send(self._reg_packet(SRTLA_REG2, os.urandom(SRTLA_ID_LEN)))
        self.log("TX REG2 probe (random id) -> expect REG_NGP")

    def send_reg1(self, uplink: Uplink) -> None:
        # [B1][B3] On REG_NGP, Moblin sends REG1 with a *new* random id to
        # create the group (RemoteConnection.swift:211-217, sendSrtlaReg1).
        uplink.send(self._reg_packet(SRTLA_REG1, os.urandom(SRTLA_ID_LEN)))
        self.log("TX REG1 (create group) -> expect REG2")

    def send_reg2_register(self, uplink: Uplink, group_id: bytes) -> None:
        # [B1] Register the connection by echoing the receiver's full group id
        # back in a REG2 (RemoteConnection.swift:202-209, :401-406).
        uplink.send(self._reg_packet(SRTLA_REG2, group_id))

    # --- main loop ----------------------------------------------------------- #
    def run(self) -> int:
        self.log(
            f"start uplink={self.bind_ip} -> {self.dst[0]}:{self.dst[1]} "
            f"local_srt={self.local_addr[1]} ip_change_at={self.ip_change_at}"
        )
        # [B1] Probe immediately once the uplink socket exists (UDP has no
        # connect handshake; Moblin probes on socket .ready).
        self.send_probe(self.uplink)
        self.state = self.WAIT_PROBE

        while not self.stop:
            self._check_timers()
            socks = [self.local, self.uplink.sock]
            if self.pending_uplink is not None:
                socks.append(self.pending_uplink.sock)
            timeout = self._next_wakeup()
            try:
                readable, _, _ = select.select(socks, [], [], timeout)
            except (InterruptedError, OSError):
                continue
            for s in readable:
                if s is self.local:
                    self._on_local()
                elif s is self.uplink.sock:
                    self._on_uplink(self.uplink)
                elif self.pending_uplink and s is self.pending_uplink.sock:
                    self._on_uplink(self.pending_uplink)

        self.log("SIGTERM -> clean shutdown")
        self.uplink.close()
        if self.pending_uplink:
            self.pending_uplink.close()
        self.local.close()
        return 0

    def _next_wakeup(self) -> float:
        if self.state != self.REGISTERED:
            return 0.25
        waits = [max(0.0, self.next_keepalive - now())]
        if self.ip_change_at is not None and not self.ip_changed and self.registered_at:
            waits.append(max(0.0, (self.registered_at + self.ip_change_at) - now()))
        return min(waits) if waits else KEEPALIVE_PERIOD_S

    def _check_timers(self) -> None:
        t = now()
        # [B6] connect timeout -> reconnect (re-probe), no backoff.
        if self.state != self.REGISTERED and (t - self.connect_started) > CONNECT_TIMEOUT_S:
            self.log("connect timeout (5s) -> reconnect (re-probe)")
            self._reconnect()
            return
        if self.state == self.REGISTERED:
            # [B2] periodic 1s keepalive on the active uplink.
            if t >= self.next_keepalive:
                self.uplink.send(self._keepalive_packet())
                self.next_keepalive = t + KEEPALIVE_PERIOD_S
                # [B6] watchdog: no packet from receiver in 5s -> reconnect.
                if (t - self.last_rx) > RX_WATCHDOG_S:
                    self.log("no receiver packet in 5s -> reconnect")
                    self._reconnect()
                    return
            # [B4] scheduled mid-stream source-IP change.
            if (
                self.ip_change_at is not None
                and not self.ip_changed
                and self.registered_at is not None
                and (t - self.registered_at) >= self.ip_change_at
            ):
                self._do_ip_change()

    def _reconnect(self) -> None:
        # [B6] Moblin reconnect = stop + startInternal: fresh socket, re-probe.
        self.uplink.close()
        self.uplink = Uplink(self.bind_ip, self.dst)
        self.state = self.CONNECTING
        self.group_id = None
        self.registered_at = None
        self.connect_started = now()
        self.send_probe(self.uplink)
        self.state = self.WAIT_PROBE

    # --- IP change ----------------------------------------------------------- #
    def _do_ip_change(self) -> None:
        # [B4] Mirrors Moblin handleNetworkPathUpdate (SrtlaClient.swift:300-346):
        # a new interface appears -> new RemoteConnection -> register() into the
        # EXISTING group via REG2 with the known group id (no new REG1). The old
        # uplink is retired once the new one is registered.
        assert self.group_id is not None
        self.log(
            f"IP-CHANGE: rebind source {self.bind_ip} -> {self.ip_change_to}; "
            f"re-register into existing group (REG2, no new REG1)"
        )
        self.pending_uplink = Uplink(self.ip_change_to, self.dst)
        self.pending_uplink.group_id = self.group_id
        self.send_reg2_register(self.pending_uplink, self.group_id)
        self.ip_changed = True

    def _promote_pending(self) -> None:
        assert self.pending_uplink is not None
        old = self.uplink
        self.uplink = self.pending_uplink
        self.pending_uplink = None
        self.bind_ip = self.uplink.bind_ip
        old.close()
        self.next_keepalive = now()  # resume keepalive on the new uplink
        self.log(
            f"IP-CHANGE: new uplink {self.bind_ip} registered into existing "
            f"group; old uplink retired (stream continuity preserved)"
        )

    # --- packet handlers ----------------------------------------------------- #
    def _on_local(self) -> None:
        try:
            data, addr = self.local.recvfrom(RECV_BUF)
        except OSError:
            return
        self.local_peer = addr
        # [B5] Once registered, relay the SRT caller's packets transparently
        # (SRTLA data packets are raw SRT packets). Before registration, drop:
        # SRT retransmits its handshake, so nothing is lost.
        if self.state == self.REGISTERED and data:
            self.uplink.send(data)

    def _on_uplink(self, uplink: Uplink) -> None:
        try:
            data = uplink.sock.recv(RECV_BUF)
        except OSError:
            return
        if not data:
            return
        self.last_rx = now()

        if is_srt_data_packet(data):
            self._forward_local(data)
            return

        type_field = u16be(data)
        if SRTLA_KEEPALIVE <= type_field <= SRTLA_REG_NAK:
            self._handle_srtla_control(uplink, type_field, data)
        else:
            # SRT control (handshake/ACK/NAK/shutdown, 0x80xx): forward to the
            # SRT caller so the end-to-end SRT session stays healthy
            # (RemoteConnection.swift:530-540 forwards non-SRTLA packets).
            self._forward_local(data)

    def _forward_local(self, data: bytes) -> None:
        if self.local_peer is not None:
            try:
                self.local.sendto(data, self.local_peer)
            except OSError:
                pass

    def _handle_srtla_control(self, uplink: Uplink, type_field: int, data: bytes) -> None:
        if type_field == SRTLA_KEEPALIVE:
            # [B2] echoed keepalive carries our timestamp back; Moblin derives
            # RTT from it (RemoteConnection.swift:431-437). Not forwarded.
            return
        if type_field == SRTLA_ACK:
            return  # SRTLA ACK: window mgmt only in Moblin; not forwarded.

        if type_field == SRTLA_REG_NGP:
            # [B3] no group -> create one with REG1.
            if uplink is self.uplink and self.state == self.WAIT_PROBE:
                self.log("RX REG_NGP")
                self.send_reg1(self.uplink)
                self.state = self.WAIT_GROUP_ID
            return

        if type_field == SRTLA_REG2:
            # [B1] group created: adopt the receiver's full id, validate the
            # first half matches what we sent (RemoteConnection.swift:448-463),
            # then register this connection with REG2.
            if len(data) != REG_LEN:
                self.log(f"RX REG2 wrong length {len(data)} (ignored)")
                return
            full_id = data[2:]
            if uplink is self.uplink and self.state == self.WAIT_GROUP_ID:
                self.group_id = full_id
                uplink.group_id = full_id
                self.log("RX REG2 (group created) -> TX REG2 (register connection)")
                self.send_reg2_register(self.uplink, full_id)
                self.state = self.WAIT_REGISTERED
            return

        if type_field == SRTLA_REG3:
            # [B1] connection registered.
            if uplink is self.pending_uplink:
                self.log("RX REG3 on new uplink")
                self._promote_pending()
                return
            if uplink is self.uplink and self.state == self.WAIT_REGISTERED:
                self.state = self.REGISTERED
                self.registered_at = now()
                self.next_keepalive = now()
                gid = self.group_id.hex()[:16] if self.group_id else "?"
                self.log(f"registered (group={gid}…) -> streaming")
            return

        if type_field == SRTLA_REG_ERR:
            # [B3] Moblin only logs REG_ERR (handleSrtlaRegErr, no retry).
            self.log("RX REG_ERR (logged, no action)")
            return
        if type_field == SRTLA_REG_NAK:
            # [B3] Moblin only logs REG_NAK.
            self.log("RX REG_NAK (logged, no action)")
            return


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Moblin SRTLA conformance mock sender")
    p.add_argument("--receiver-host", default="127.0.0.1")
    p.add_argument("--receiver-port", type=int, default=5000)
    p.add_argument("--local-srt-port", type=int, default=6000,
                   help="local UDP port the SRT caller (ffmpeg) connects to")
    p.add_argument("--bind-ip", default="127.0.0.1",
                   help="source IP for the SRTLA uplink socket")
    p.add_argument("--ip-change-at-sec", type=float, default=None,
                   help="seconds after registration to change the source IP "
                        "mid-stream (re-register into the existing group)")
    p.add_argument("--ip-change-to", default="127.0.0.2",
                   help="new source IP to rebind to on --ip-change-at-sec")
    return p.parse_args(argv)


def main(argv: list[str]) -> int:
    return MoblinMock(parse_args(argv)).run()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

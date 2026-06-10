# Moblin SRTLA client — documented behaviours

This file is the **source of truth** for `moblin_mock.py`. Every wire behaviour
the mock implements is keyed to an entry below (`[B1]`..`[B7]`). The mock must
not silently drift from this document: change a behaviour in one place and you
change it in the other.

All citations are to **Moblin** pinned at commit
[`0ae5294950166978064840bc874bfed3a8cf03a4`](https://github.com/eerimoq/moblin/tree/0ae5294950166978064840bc874bfed3a8cf03a4)
(matches the `moblin-mock` pin in `tests/compat/matrix.yaml`). Permalinks point
at that SHA, so line numbers are stable.

Moblin's SRTLA client lives in `Moblin/Media/Srtla/`:

| File | Role |
|------|------|
| [`Common/Srtla.swift`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Common/Srtla.swift) | SRTLA packet types + `createSrtlaPacket` |
| [`Common/Srt.swift`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Common/Srt.swift) | SRT control-bit, data/control discriminator |
| [`Client/SrtlaClient.swift`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/SrtlaClient.swift) | Group-level state machine, connection selection, path monitor |
| [`Client/RemoteConnection.swift`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift) | Per-uplink socket: REG flow, keepalive, window, reconnect |
| [`Client/LocalListener.swift`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/LocalListener.swift) | Local UDP listener the SRT caller connects to |

### Wire type constants

SRTLA packet types are defined in
[`Srtla.swift#L7-L16`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Common/Srtla.swift#L7-L16)
and OR'd with the SRT control bit `0x8000`
([`Srtla.swift#L18-L21`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Common/Srtla.swift#L18-L21),
[`Srt.swift#L3`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Common/Srt.swift#L3))
to produce the on-the-wire value. These match our receiver's `common.h`:

| Moblin enum (`Srtla.swift`) | On wire (post-OR) | `srtla/src/common.h` |
|---|---|---|
| `keepalive = 0x1000` | `0x9000` | `SRTLA_TYPE_KEEPALIVE` |
| `ack = 0x1100` | `0x9100` | `SRTLA_TYPE_ACK` |
| `reg1 = 0x1200` | `0x9200` | `SRTLA_TYPE_REG1` |
| `reg2 = 0x1201` | `0x9201` | `SRTLA_TYPE_REG2` |
| `reg3 = 0x1202` | `0x9202` | `SRTLA_TYPE_REG3` |
| `regErr = 0x1210` | `0x9210` | `SRTLA_TYPE_REG_ERR` |
| `regNgp = 0x1211` | `0x9211` | `SRTLA_TYPE_REG_NGP` |
| `regNak = 0x1212` | `0x9212` | `SRTLA_TYPE_REG_NAK` |

---

## [B1] Registration: REG2 *probe* first → REG_NGP → REG1 → REG2 → REG2 → REG3

Moblin does **not** open with REG1. When an uplink socket becomes ready it sends
a **REG2 "probe" carrying a random 256-byte group id**; only after the receiver
answers `REG_NGP` (no such group) does it send `REG1` to create the group. This
is the load-bearing handshake quirk the mock must reproduce.

Trace:

1. Socket `.ready` → connection state becomes `shouldSendRegisterRequest`, then
   the delegate is told the socket connected —
   [`RemoteConnection.swift#L303-L331`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L303-L331).
2. `remoteConnectionOnSocketConnected` → `connection.probe()` —
   [`SrtlaClient.swift#L432-L442`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/SrtlaClient.swift#L432-L442).
3. `probe()` sets a **random** 256-byte `groupId` and sends it as **REG2** —
   [`RemoteConnection.swift#L197-L200`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L197-L200)
   + `sendSrtlaReg2`
   [`#L401-L406`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L401-L406).
4. On `REG_NGP`, `remoteConnectionOnRegNgp` → `connection.sendSrtlaReg1()` —
   [`SrtlaClient.swift#L444-L450`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/SrtlaClient.swift#L444-L450).
5. `sendSrtlaReg1()` generates a **new** random 256-byte id and sends **REG1** —
   [`RemoteConnection.swift#L211-L217`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L211-L217).
6. On `REG2`, `handleSrtlaReg2` requires `packet.count == 258` and that the
   **first half (128 bytes)** of the returned id matches the id it sent, then
   adopts the receiver's full id —
   [`RemoteConnection.swift#L448-L463`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L448-L463).
7. `remoteConnectionOnReg2` stores the group id and calls `register(groupId:)`
   on every connection —
   [`SrtlaClient.swift#L452-L461`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/SrtlaClient.swift#L452-L461);
   `register` sends **REG2** with the full id —
   [`RemoteConnection.swift#L202-L209`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L202-L209).
8. On `REG3`, `handleSrtlaReg3` marks the connection `registered` and starts the
   keepalive timer —
   [`RemoteConnection.swift#L465-L480`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L465-L480).

**On-wire sequence (one uplink):**
`REG2(random)` → `REG_NGP` → `REG1(random)` → `REG2(full id)` → `REG2(full id)` → `REG3`.

**Compatibility note.** Our receiver answers an unknown REG2 with `REG_NGP`
(`srtla/src/protocol/srtla_handler.cpp:242-253`) and preserves the first 128
bytes of the sender's REG1 id in the group id
(`srtla/src/connection/connection_group.cpp:18-28`), so Moblin's probe-first flow
and its first-half validation both succeed against `srtla_rec` unmodified.

**Mock:** replicated. `MoblinMock.send_probe` / `send_reg1` / `send_reg2_register`
and the `WAIT_PROBE → WAIT_GROUP_ID → WAIT_REGISTERED → REGISTERED` state machine.

---

## [B2] Keepalive: 10-byte, timestamped, every 1 s — **never** extended

Moblin's keepalive is **10 bytes**: the 2-byte type `0x9000` followed by an
**8-byte big-endian int64 millisecond timestamp**. It is sent once per second on
each registered uplink. Moblin has no notion of an "extended" keepalive — the
only keepalive type defined is `0x1000`
([`Srtla.swift#L7-L16`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Common/Srtla.swift#L7-L16)).

- `sendSrtlaKeepalive` builds `srtControlTypeSize + 8` bytes and writes the
  timestamp at offset 2 —
  [`RemoteConnection.swift#L408-L412`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L408-L412);
  `getKeepAliveTime` is ms since the connection base time —
  [`#L414-L416`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L414-L416).
- The keepalive timer fires every `interval: 1` second after `REG3` —
  [`RemoteConnection.swift#L473-L479`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L473-L479).
- The receiver echoes the keepalive; Moblin reads the echoed timestamp back to
  compute RTT —
  [`RemoteConnection.swift#L431-L437`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L431-L437).

> **Correction to a prior assumption.** Earlier task notes claimed Moblin emits a
> bare 2-byte keepalive. The pinned source emits the **10-byte timestamped**
> form. Our receiver accepts it: `is_srtla_keepalive` checks only the type byte
> (`srtla/src/common.c:109-111`) and `parse_keepalive_conn_info` requires ≥38
> bytes (`common.c:131-134`), so a 10-byte keepalive is correctly classified as
> "no sender telemetry" (not the 38-byte extended `0xC01F` variant) and is echoed
> back (`srtla_handler.cpp:456-458`). The mock therefore sends the faithful
> 10-byte keepalive and **never** the extended one.

**Mock:** replicated. `MoblinMock._keepalive_packet` (10 bytes) + 1 s timer.

---

## [B3] Reaction to REG_NGP / REG_ERR / REG_NAK

| Response | Moblin reaction | Citation |
|---|---|---|
| `REG_NGP` | send `REG1` to create the group (drives the normal handshake) | `handleSrtlaRegNgp` [`#L486-L489`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L486-L489) → `SrtlaClient.swift#L444-L450` |
| `REG_ERR` | **log only**, no retry / no backoff | `handleSrtlaRegErr` [`#L482-L484`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L482-L484) |
| `REG_NAK` | **log only**, no action | `handleSrtlaRegNak` [`#L491-L493`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L491-L493) |

Recovery from a stuck handshake is not REG-driven — it comes from the connect
timer (see [B6]), which re-runs the probe.

**Mock:** replicated. `_handle_srtla_control` handles `REG_NGP` (→ REG1) and logs
`REG_ERR` / `REG_NAK` without acting.

---

## [B4] Source-IP / network-path change mid-stream — re-register, don't recreate

When the set of network interfaces changes, Moblin does **not** tear down the
group. For each newly-available interface it creates a fresh `RemoteConnection`,
starts it, and immediately `register(groupId:)`s it **into the existing group**
using a `REG2` with the known group id — no new `REG1`. Vanished interfaces are
stopped.

- `handleNetworkPathUpdate`: stop connections whose interface disappeared; for
  each new interface create a `RemoteConnection`, `startRemote`, and if a
  `groupId` already exists, `register(groupId:)` it —
  [`SrtlaClient.swift#L300-L346`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/SrtlaClient.swift#L300-L346).
- `register(groupId:)` sends `REG2` with the existing id —
  [`RemoteConnection.swift#L202-L209`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L202-L209).
- An uplink is pinned to its interface via `params.requiredInterface` (the
  equivalent of binding the source socket to an interface's IP) —
  [`RemoteConnection.swift#L137-L144`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L137-L144).

**Expected receiver behaviour (asserted by the IP-change test).** A `REG2` from a
*new* source address carrying a *known* group id matches the existing group, so
`register_connection` adds the new connection and replies `REG3` — it does **not**
create a second group (`srtla/src/protocol/srtla_handler.cpp:242-308`,
`find_group_by_id`). The group, and the SRT stream it carries, continue
uninterrupted; the old connection later ages out at `CONN_TIMEOUT` (15 s).

**Mock:** replicated. `--ip-change-at-sec N` → `_do_ip_change` binds a new uplink
socket to `--ip-change-to` and re-registers into the current group with `REG2`
(no new `REG1`); `_promote_pending` switches the active uplink on the new uplink's
`REG3` and retires the old one.

---

## [B5] SRT data handling: transparent passthrough (Moblin's framing documented)

In Moblin a packet is data vs. control by its top bit
(`isSrtDataPacket → (packet[0] & 0x80) == 0`,
[`Srt.swift#L18-L20`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Common/Srt.swift#L18-L20)).
SRTLA **data** packets are raw SRT packets; only **control** packets carry SRTLA
headers (`sendPacket`,
[`RemoteConnection.swift#L358-L379`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L358-L379)).
Non-SRTLA packets received from the receiver (SRT ACK/NAK/handshake and data) are
forwarded to the local SRT listener
([`RemoteConnection.swift#L530-L540`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L530-L540)).

Moblin additionally applies its **own** SRT framing to packets it generates
internally — it pads short data packets with null MPEG-TS packets up to
`mpegtsPacketsPerPacket` and batches sends:

- null-padding + `nullPacket` —
  [`RemoteConnection.swift#L358-L379`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L358-L379),
  [`#L69-L75`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L69-L75);
- batched flush at >15 queued packets / every 15 ms —
  [`RemoteConnection.swift#L385-L399`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L385-L399),
  [`SrtlaClient.swift#L245-L253`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/SrtlaClient.swift#L245-L253);
- control packets sent immediately —
  [`RemoteConnection.swift#L381-L383`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L381-L383).

**Mock fidelity: documented, not replicated — deliberately.** The conformance
mock carries a **genuine external SRT caller** stream (ffmpeg), which already
produces complete, correctly-sized SRT packets. Re-applying Moblin's internal
MPEG-TS null-padding would append bytes to a finished SRT packet and corrupt it
at the sink. The mock therefore forwards SRT data packets **unmodified** — exactly
how `srtla_send` relays its SRT caller — while preserving the data/control split
and forward-to-listener behaviour above. This is the one behaviour the mock does
not reproduce on the wire, and it is called out here so there is no silent drift.

**Mock:** `is_srt_data_packet` + `_on_local` (forward when registered) / `_on_uplink`
(forward non-SRTLA control + data to the local SRT caller).

---

## [B6] Reconnect / watchdog timers — immediate, no backoff

- **Connect timeout:** on socket `.ready` a 5 s single-shot timer is armed; if
  registration has not completed it calls `reconnect` —
  [`RemoteConnection.swift#L308-L311`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L308-L311).
- **Receive watchdog:** the 1 s keepalive timer also reconnects if no packet has
  arrived from the receiver in the last 5 s —
  [`RemoteConnection.swift#L476-L478`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L476-L478).
- **Reconnect = stop + restart** (fresh socket, re-probe) with **no backoff** —
  [`reconnect`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L333-L336),
  also triggered on socket `.failed`
  [`#L326-L327`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L326-L327).
- A group-level connect timeout also exists in the client —
  [`SrtlaClient.swift#L120-L124`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/SrtlaClient.swift#L120-L124).

**Mock:** replicated. `_check_timers` enforces the 5 s connect timeout and the
5 s receive watchdog; `_reconnect` rebuilds the uplink and re-probes with no
backoff.

---

## [B7] Connection scoring / selection (bonus — single-uplink no-op here)

Moblin picks, per packet, the highest-scoring registered uplink:
`windowSize / (inFlight + 1)` scaled by the configured priority —
`score()` [`RemoteConnection.swift#L160-L181`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L160-L181),
`selectRemoteConnection`
[`SrtlaClient.swift#L417-L428`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/SrtlaClient.swift#L417-L428).
The window adapts on SRT NAK (`-100`) and SRTLA ACK (`+1` / `+29`) —
[`RemoteConnection.swift#L223-L237`](https://github.com/eerimoq/moblin/blob/0ae5294950166978064840bc874bfed3a8cf03a4/Moblin/Media/Srtla/Client/RemoteConnection.swift#L223-L237).

**Mock fidelity: documented, not replicated.** The conformance pair and the
IP-change scenario each run a single active uplink at a time, so selection is a
no-op; the mock always sends on its one active uplink. Documented for
completeness and to bound the mock's scope.

---

## Behaviour → mock map

| ID | Behaviour | Mock symbol | Replicated on wire? |
|----|-----------|-------------|---------------------|
| B1 | REG2-probe → NGP → REG1 → REG2 → REG2 → REG3 | `send_probe`/`send_reg1`/`send_reg2_register`, state machine | Yes |
| B2 | 10-byte timestamped keepalive @1 s, never extended | `_keepalive_packet`, 1 s timer | Yes |
| B3 | REG_NGP→REG1; REG_ERR/REG_NAK log-only | `_handle_srtla_control` | Yes |
| B4 | IP change → re-register into existing group (REG2, no REG1) | `_do_ip_change` / `_promote_pending` | Yes |
| B5 | SRT data passthrough (Moblin MPEG-TS framing) | `_on_local` / `_on_uplink` | Passthrough only (framing documented, not replicated — see B5) |
| B6 | 5 s connect timeout + 5 s receive watchdog, no backoff | `_check_timers` / `_reconnect` | Yes |
| B7 | Window-based uplink scoring | n/a (single uplink) | Documented, not replicated |

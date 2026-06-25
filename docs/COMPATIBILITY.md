# SRTLA Ecosystem Compatibility

This document captures the SRTLA ecosystem landscape, our wire-format extensions, known
interoperability issues, and the compatibility guarantees this repo commits to. It is the
distilled reference for protocol engineers and maintainers.

The live implementation registry is [`tests/compat/matrix.yaml`](../tests/compat/matrix.yaml).
That file is the authoritative pin source; this document explains the *why* behind it.

For protocol internals and the handshake flow, see [`HOW_IT_WORKS.md`](HOW_IT_WORKS.md).

---

## 1. Ecosystem Table

| Implementation | Language | Role | Pin | Tier |
|---|---|---|---|---|
| BELABOX/srtla | C | sender + receiver | `6f3925e` (oldest srtla2) | 1 — reference |
| irlserver/srtla | C++ | receiver | `main` (no tags) | 1 — upstream base |
| irlserver/srtla_send | Rust | sender | `v3.0.0` | 1 — extended-KA sender |
| CERALIVE/srtla-send-rs | Rust | sender | `v1.0.0` (`b867c7d`) | 1 — fork; ADR-003 cutover sender |
| eerimoq/moblin | Swift | sender (iOS) | `ios-33.8.0-90` | 1 — real-world client |
| e04/go-irl | Go | receiver + UI | `main` (no tags) | 2 — Go receiver |
| e04/go-srtla | Go | receiver | `main` (no tags) | 2 — Go receiver (minimal) |
| OpenIRL/srtla-receiver | Shell/C | receiver | `main` (no tags) | 2 — Docker wrapper |
| datagutt/moblink-rust | Rust | sender | `main` (no tags) | 3 — early-stage |
| yannismate/srtla-rs | Rust | unknown | `main` | 3 — unmaintained |

Tier 1 = must pass in CI. Tier 2 = should pass. Tier 3 = informational only.

Pins are recorded in `tests/compat/matrix.yaml`. Update that file when refreshing; do not
edit pins here directly.

---

## 2. Protocol Consensus

All implementations speak **SRTLA v1**. The wire format is stable across the entire
ecosystem.

### Packet types

Authoritative source: `src/common.h` lines 35-42.

| Constant | Value | Length | Purpose |
|---|---|---|---|
| `SRTLA_TYPE_KEEPALIVE` | `0x9000` | 10 bytes (std) / 38 bytes (ext) | Heartbeat + RTT |
| `SRTLA_TYPE_ACK` | `0x9100` | 4 + 4×count | Batch ACK for congestion control |
| `SRTLA_TYPE_REG1` | `0x9200` | 258 bytes | Sender initiates registration |
| `SRTLA_TYPE_REG2` | `0x9201` | 258 bytes | Receiver responds with full ID |
| `SRTLA_TYPE_REG3` | `0x9202` | 2 bytes | Sender confirms link |
| `SRTLA_TYPE_REG_ERR` | `0x9210` | 2 bytes | Registration error |
| `SRTLA_TYPE_REG_NGP` | `0x9211` | 2 bytes | No group present (triggers re-reg) |
| `SRTLA_TYPE_REG_NAK` | `0x9212` | 2 bytes | Registration NAK (CeraLive-only) |

Other shared constants: `SRTLA_ID_LEN` = 256 bytes, keepalive period = 1 s,
connection/group timeout = 4 s (upstream default; CeraLive uses 15 s / 30 s for
cellular resilience — see `src/receiver_config.h`).

### Protocol generation boundary: srtla1 vs srtla2

BELABOX's git history contains two protocol generations, and the distinction
matters for how the compat matrix pins BELABOX:

- **srtla1** (BELABOX before commit `6f3925e`, 2021-02-04): keepalive + ACK only
  (`0x9000` / `0x9100`). No `REG1`/`REG2`/`REG3`, no connection groups. A sender
  this old simply gets `no reply` from a modern receiver and aborts.
- **srtla2** (BELABOX `6f3925e` onward — *"srtla2: now with receiver support for
  multiple connections"*): introduces the `REG1`/`REG2`/`REG3` registration
  handshake and connection groups. Every implementation in the table above —
  and the entire wire format documented in this file — is srtla2.

The matrix pins BELABOX at the **oldest srtla2 commit** (`6f3925e`) on purpose:
it maximizes backward-compat coverage by proving our `srtla_rec` still registers
the earliest registration-capable BELABOX build (Feb 2021). **srtla1 is
intentionally out of scope** — our receiver correctly does not interoperate with
a pre-handshake sender, and that non-interop is not a regression. Do not "fix" a
red blocking pair by pinning BELABOX back to a pre-`6f3925e` SHA; that swaps a
real backward-compat assertion for a test against a dead protocol generation.

### Our extensions

We diverge from upstream in exactly two places:

**1. Extended keepalive (`SRTLA_KEEPALIVE_MAGIC 0xC01F`)**

Standard keepalive is 10 bytes (type + timestamp). We extend it to 38 bytes when the
sender supports it. The extra payload carries per-link telemetry:

```
Bytes  0-1:   Type (0x9000)
Bytes  2-9:   Timestamp (u64 ms)
Bytes 10-11:  Magic (0xC01F)          ← SRTLA_KEEPALIVE_MAGIC
Bytes 12-13:  Version (0x0001)        ← SRTLA_KEEPALIVE_EXT_VERSION
Bytes 14-17:  Connection ID (u32)
Bytes 18-21:  Window (i32)
Bytes 22-25:  In-flight (i32)
Bytes 26-29:  RTT ms (u32)
Bytes 30-33:  NAK count (u32)
Bytes 34-37:  Bitrate bytes/sec (u32)
```

Backwards compatibility: receivers that don't understand the extension read bytes 0-9
and ignore the rest. This is safe by design — no receiver crashes on an oversized
keepalive.

Constants defined in `src/common.h`:
- `SRTLA_KEEPALIVE_MAGIC 0xC01F`
- `SRTLA_KEEPALIVE_STD_LEN 10`
- `SRTLA_KEEPALIVE_EXT_LEN 38`
- `SRTLA_KEEPALIVE_EXT_VERSION 0x0001`

**2. `SRTLA_TYPE_REG_NAK` (`0x9212`)**

This packet type is CeraLive-only. Upstream implementations do not send or expect it.
It signals a registration NAK distinct from `REG_ERR` (temporary failure) and `REG_NGP`
(no group). Any receiver that doesn't recognise `0x9212` will silently drop it, which
is acceptable — the sender will time out and retry.

---

## 3. Known Ecosystem Issues

### REG3/NGP race condition
**Severity**: Medium. **Status**: Fixed upstream.

When multiple connections register simultaneously, a race between the REG3 response and
a REG_NGP packet could cause registration failures. Fixed in irlserver/srtla_send v2.2.0+
(commit `f138fb4`). BELABOX/srtla (C reference) does not have the fix. Our CI pins
irlserver/srtla_send at v3.0.0, which includes the fix.

### Handshake broadcast removal (May 2026)
**Severity**: Unknown. **Status**: Requires validation.

irlserver/srtla commit `2de6dbb` (2026-05-02) removed handshake broadcast on all
connections, sending only on the first. This may affect multi-connection registration
timing with older senders. Tier 1 CI covers this pair; watch for registration timeouts.

### ACK throttling removal (May 2026)
**Severity**: Low. **Status**: Aligned, monitoring recommended.

irlserver/srtla commit `629d241` (2026-05-20) removed SRTLA ACK throttling. ACKs now
go out every `RECV_ACK_INT` (10) packets rather than being rate-limited. CeraLive
aligned with this decision (see `HOW_IT_WORKS.md` for the rationale). On high-loss
links the increased ACK volume is worth watching.

### Moblin IP-change quirk
**Severity**: Low. **Status**: Expected behaviour.

When Moblin (iOS) switches networks (WiFi to cellular), it briefly disconnects and
reconnects via `NWPathMonitor`. The reconnection is automatic. No action needed on the
receiver side; the 15 s `CONN_TIMEOUT` absorbs the gap.

### Extended keepalive mismatch
**Severity**: Low. **Status**: Backwards compatible by design.

Senders that don't support the extended format (BELABOX, Moblin, Go implementations)
send standard 10-byte keepalives. Our receiver handles both lengths. Senders that do
support it (irlserver/srtla_send v3.0+) get per-link telemetry; others don't. No
functional impact on stream delivery.

---

## 4. Compatibility Guarantees

The matrix in `tests/compat/matrix.yaml` locks the following:

1. **Tier 1 sender/receiver pairs must register and pass data** at the pinned versions.
   A CI failure in any Tier 1 pair blocks merge.

2. **Extended keepalive is backwards compatible.** Any sender that sends a standard
   10-byte keepalive will work with our receiver. Any receiver that doesn't understand
   the extension will work with our sender.

3. **`0x9212` (REG_NAK) is additive.** We never require a remote to understand it.
   Senders that don't recognise it will time out and retry, which is the correct
   fallback.

4. **Wire constants match `src/common.h` exactly.** No implementation-specific
   remapping. The hex values in this document are copied from that file and must stay
   in sync with it.

5. **Timeouts are receiver-local.** Our `CONN_TIMEOUT` (15 s) and `GROUP_TIMEOUT`
   (30 s) are more generous than the upstream 4 s defaults to accommodate cellular
   link flapping. This is a receiver-side tunable and does not affect wire compatibility.

---

## 5. srt-patch Necessity

The CeraLive stack uses two patched libsrt forks (CERALIVE/srt for the device image; irlserver/srt `belabox` branch for `irl-srt-server`). ADR-002 documents the empirical A/B/C evaluation that determined which patch behaviors are necessary, which are replaceable by standard SRT options, and the ordered steps to remove the dependency. See [`docs/adr/ADR-002-srt-patch-necessity.md`](adr/ADR-002-srt-patch-necessity.md).

---

## 6. SRT FEC Connect-Matrix (one-sided packet-filter negotiation)

FEC is an **SRT-level** feature: `SRTO_PACKETFILTER=fec` is negotiated in the SRT
handshake, end-to-end between the caller and the listener. SRTLA underneath is a
transparent UDP relay and does not touch it — so a FEC stream "rides" whichever
SRT listener it terminates on. The receive-profile design uses one **fec-accept**
listener (L1, `SRTO_PACKETFILTER=fec` — just the type) for device senders. This
matrix proves that one such listener serves both FEC and non-FEC senders, and
where the negotiation actually hard-fails.

The caller is the device (initiator); the listener is the cloud receiver
(responder). Filter strings: a full-config FEC sender is
`fec,layout:staircase,rows:10,cols:10,arq:onreq`; the fec-accept listener is just
`fec`.

| # | Caller (sender) | Listener config | Result | Negotiated `SRTO_PACKETFILTER` on accepted socket |
|---|---|---|---|---|
| a | FEC (full config) | `fec` (fec-accept) | **Connect — FEC negotiated** | non-empty (merged config) |
| b | plain (no filter) | `fec` (fec-accept) | **Connect — PLAIN** (responder clears it per-connection) | empty `""` |
| c | FEC (full config) | conflicting `fec,…` (incompatible dims) | **HARD REJECT — `SRT_REJ_FILTER`** | n/a (no accept, 0 bytes) |
| d | FEC (full config) | *no packetfilter* (empty) | **Connect — FEC adopted** by the listener ("good deal") | non-empty (caller's config) |

**Why case (b) means no separate FEC listener is needed.** A listener that set a
filter the caller never requested does not reject — the responder branch in
`srtcore/core.cpp` (`checkApplyFilterConfig` + the post-handshake check "agent has
configured packetfilter, but peer didn't request it") **clears** the filter for
that one connection and connects plain. So the single fec-accept L1 accepts a FEC
device (case a, full negotiation) **and** a non-FEC sender such as BELABOX
(case b, cleared per-connection). One listener, both senders — no second FEC port.

**Where the reject boundary actually is.** The genuine `SRT_REJ_FILTER` hard
reject (case c) is a filter-config **conflict**, *not* the mere absence of a
filter. A listener with **no** packetfilter does **not** reject a FEC caller — it
takes the caller's config as a "good deal" and runs FEC anyway (case d). This
corrects the earlier mental model that a "non-FEC listener" would reject a FEC
sender: on a packet-filter-capable libsrt (≥ 1.4.0; system libsrt 1.5.x) absence
is permissive (adopt), and only an irreconcilable config closes the connection.
The one-sided config rule is documented upstream in
[`srt/docs/features/packet-filtering-and-fec.md`](https://github.com/Haivision/srt/blob/master/docs/features/packet-filtering-and-fec.md)
("one party defines the full configuration while the other only defines the
matching packet filter type … if the options specified are in conflict, the
connection will be rejected").

This matrix is exercised end-to-end by the
[`fec-connect-matrix`](../tests/compat/scenarios/fec-connect-matrix.sh) harness
scenario, which drives a real FEC/plain SRT caller into `srt-sink --packetfilter`
and asserts the negotiated filter the sink reads off each accepted socket
(`"packetfilter"` in the result JSON). Cases (a)+(b)+(c) gate the scenario;
case (d) is recorded as an informational observation.

---

## 7. ENABLE_ALGO_COMPARISON Decision

`ENABLE_ALGO_COMPARISON` is defined in `src/receiver_config.h` with a default of `1`:

```cpp
#ifndef ENABLE_ALGO_COMPARISON
#define ENABLE_ALGO_COMPARISON 1
#endif
```

**Decision: stays `1` for the duration of this program.**

Rationale: the flag enables side-by-side comparison of the legacy and new connection
quality algorithms. Keeping it on lets us collect production data on both paths without
committing to either. Final algorithm selection is explicitly deferred — it is out of
scope for the current work and will be a separate decision with its own evidence gate.

Changing this default requires a deliberate ADR, not a drive-by edit.

---

## 8. Maintenance Policy

### Pin refresh
When a Tier 1 or Tier 2 implementation cuts a new release, update the pin in
`tests/compat/matrix.yaml` and run the full Tier 1 CI suite before merging. Do not
update pins in this document directly.

### Weekly drift job
A scheduled CI job checks for new commits on `main`-tracked implementations (those
without stable tags). If the job detects drift, it opens a tracking issue. The on-call
maintainer triages within one week.

### Adding a new implementation
1. Add it to `tests/compat/matrix.yaml` with tier, pin, and language.
2. Run at least one sender/receiver pair test against our receiver.
3. Document any quirks in section 3 of this file.
4. Open a PR with both changes together.

### Removing an implementation
Implementations that go unmaintained for 12+ months (e.g. yannismate/srtla-rs) are
downgraded to Tier 3 and eventually removed from the matrix. They stay in the ecosystem
table above for historical reference until the next major version of this document.

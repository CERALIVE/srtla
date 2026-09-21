# SRTLA Ecosystem Compatibility

This document captures the SRTLA ecosystem landscape, the wire-format extensions this
receiver understands, known interoperability issues, and the compatibility guarantees
this repo commits to. It is the distilled reference for protocol engineers and
maintainers.

The live implementation registry is [`tests/compat/matrix.yaml`](../tests/compat/matrix.yaml).
That file is the authoritative pin source; this document explains the *why* behind it.

For protocol internals and the handshake flow, see [`HOW_IT_WORKS.md`](HOW_IT_WORKS.md).

---

## 1. Ecosystem Table

| Implementation | Language | Role | Addressed by | Tier |
|---|---|---|---|---|
| BELABOX/srtla | C | sender + receiver | `pin` `6f3925e` (oldest srtla2) | 1 (reference) |
| irlserver/srtla | C++ | receiver | this repo's fork base `b8359bc` | 1 (upstream base) |
| irlserver/srtla_send | Rust | sender | `pin` `ef95926` | 1 (extended-KA sender) |
| CERALIVE/srtla-send-rs | Rust | sender | `ref: main` (canonical branch) | 1 (shipping sender) |
| eerimoq/moblin | Swift | sender (iOS) | `pin` `0ae5294`, exercised via `moblin-mock` | 1 (real-world client) |
| OpenIRL/srtla-receiver | Shell/C | receiver | `pin` `d8fd677` (srtla_rec component only) | 1 (Docker wrapper) |
| e04/go-srtla | Go | receiver | `pin` `8a3b55b` | 2 (Go receiver, minimal) |
| e04/go-irl | Go | receiver + UI | `pin` `fa9c118` (server mode only) | 2 (Go receiver) |
| datagutt/moblink-rust | Rust | relay | excluded: WebSocket Moblink protocol, not SRTLA | n/a |

Tier 1 = must pass in CI (the `blocking` pairs). Tier 2 = should pass (`informational`).

Every third-party implementation is addressed by an immutable 40-hex `pin:`; CERALIVE's
sender uses `ref: main` to follow source development, and the libsrt build default uses
the published `srt-v1.5.7+ceralive.2` tag. `tests/compat/validate-matrix.py` enforces
"exactly one of the two". Update `matrix.yaml` when refreshing; do not edit pins here.

The pairs the matrix runs: every Tier 1 sender against **our** receiver, our receiver's
companion sender (`ours`, the C reference sender built from `src/sender.cpp`) against
every ecosystem receiver, and the CERALIVE Rust sender against every ecosystem receiver.
The `ours -> ours` pair exists to verify extended-keepalive activation end to end.

---

## 2. Protocol Consensus

All implementations speak **SRTLA v2** ("srtla2"). The wire format is stable across the
entire ecosystem.

### Packet types

Authoritative source: `src/common.h`.

| Constant | Value | Length | Purpose |
|---|---|---|---|
| `SRTLA_TYPE_KEEPALIVE` | `0x9000` | 2 (bare) / 10 (std) / 38 (ext) bytes | Heartbeat, optionally RTT + telemetry |
| `SRTLA_TYPE_ACK` | `0x9100` | 4 + 4×count | Batch ACK for congestion control |
| `SRTLA_TYPE_REG1` | `0x9200` | 258 bytes | Sender initiates registration |
| `SRTLA_TYPE_REG2` | `0x9201` | 258 bytes | Receiver responds with full ID / sender joins a link |
| `SRTLA_TYPE_REG3` | `0x9202` | 2 bytes | Receiver confirms link |
| `SRTLA_TYPE_REG_ERR` | `0x9210` | 2 bytes | Registration error |
| `SRTLA_TYPE_REG_NGP` | `0x9211` | 2 bytes | No group present (triggers re-reg) |
| `SRTLA_TYPE_REG_NAK` | `0x9212` | 2 bytes | Defined in `common.h`; never emitted by this receiver |

Other shared constants: `SRTLA_ID_LEN` = 256 bytes, keepalive period = 1 s. Connection
and group timeouts are receiver-local: this receiver uses `CONN_TIMEOUT` = 15 s and
`GROUP_TIMEOUT` = 30 s (`src/receiver_config.h`); BELABOX's original receiver used 4 s.

### Protocol generation boundary: srtla1 vs srtla2

BELABOX's git history contains two protocol generations, and the distinction matters
for how the compat matrix pins BELABOX:

- **srtla1** (BELABOX before commit `6f3925e`, 2021-02-04): keepalive + ACK only
  (`0x9000` / `0x9100`). No `REG1`/`REG2`/`REG3`, no connection groups. A sender this
  old simply gets `no reply` from a modern receiver and aborts.
- **srtla2** (BELABOX `6f3925e` onward, *"srtla2: now with receiver support for
  multiple connections"*): introduces the `REG1`/`REG2`/`REG3` registration handshake
  and connection groups. Every implementation in the table above, and the entire wire
  format documented in this file, is srtla2.

The matrix pins BELABOX at the **oldest srtla2 commit** (`6f3925e`) on purpose: it
maximizes backward-compat coverage by proving our `srtla_rec` still registers the
earliest registration-capable BELABOX build (Feb 2021). **srtla1 is intentionally out
of scope.** Our receiver correctly does not interoperate with a pre-handshake sender,
and that non-interop is not a regression. Do not "fix" a red blocking pair by pinning
BELABOX back to a pre-`6f3925e` SHA; that swaps a real backward-compat assertion for a
test against a dead protocol generation.

### Extended keepalive (`SRTLA_KEEPALIVE_MAGIC 0xC01F`)

The one extension beyond BELABOX's wire format. It originates in irlserver's sender and
receiver, so this receiver inherits it unmodified from upstream. The standard keepalive
is 10 bytes (type + timestamp); a capable sender extends it to 38 bytes carrying
per-link telemetry:

```
Bytes  0-1:   Type (0x9000)
Bytes  2-9:   Timestamp (u64 ms)
Bytes 10-11:  Magic (0xC01F)          <- SRTLA_KEEPALIVE_MAGIC
Bytes 12-13:  Version (0x0001)        <- SRTLA_KEEPALIVE_EXT_VERSION
Bytes 14-17:  Connection ID (u32)
Bytes 18-21:  Window (i32)
Bytes 22-25:  In-flight (i32)
Bytes 26-29:  RTT ms (u32)
Bytes 30-33:  NAK count (u32)
Bytes 34-37:  Bitrate bytes/sec (u32)
```

Backwards compatibility: receivers that don't understand the extension read bytes 0-9
(or just the 2-byte type) and echo what they got. No receiver in the table crashes on
an oversized keepalive. Senders that don't support the extension keep working against
this receiver; they just get the receiver-only quality path.

Constants defined in `src/common.h`: `SRTLA_KEEPALIVE_MAGIC 0xC01F`,
`SRTLA_KEEPALIVE_STD_LEN 10`, `SRTLA_KEEPALIVE_EXT_LEN 38`,
`SRTLA_KEEPALIVE_EXT_VERSION 0x0001`.

### 32-byte control padding

This receiver pads every control reply shorter than 32 bytes up to 32
(`src/protocol/pad_sendto.h`). Some carrier NATs drop tiny UDP frames instead of
refreshing the mapping. Every SRTLA implementation ignores trailing bytes on 2-byte
control types, so this is safe against the whole table; `tests/test_pad_sendto.cpp`
pins the behaviour.

---

## 3. Known Ecosystem Issues

### REG3/NGP race condition
**Severity**: Medium. **Status**: Fixed in irlserver's sender.

When multiple connections register simultaneously, a race between the REG3 response
and a REG_NGP packet could cause registration failures. Fixed in irlserver/srtla_send
v2.2.0+ (commit `f138fb4`). BELABOX/srtla (C reference) does not have the fix. The
matrix pins irlserver/srtla_send well past it, and `srtla-send-rs` inherits the fix.

### Handshake broadcast removal (May 2026)
**Severity**: Unknown. **Status**: Covered by the blocking tier.

irlserver/srtla commit `2de6dbb` (2026-05-02) stopped broadcasting the SRT handshake on
all connections, sending only on the first. This may affect multi-connection
registration timing with older senders. Tier 1 CI covers this pair; watch for
registration timeouts.

### ACK throttling removal (May 2026)
**Severity**: Low. **Status**: Inherited from upstream, monitoring recommended.

irlserver/srtla commit `629d241` (2026-05-20) removed SRTLA ACK throttling. ACKs now go
out every `RECV_ACK_INT` (10) packets rather than being rate-limited (see
`HOW_IT_WORKS.md` for the rationale). On high-loss links the increased ACK volume is
worth watching.

### Moblin IP-change quirk
**Severity**: Low. **Status**: Expected behaviour.

When Moblin (iOS) switches networks (WiFi to cellular), it briefly disconnects and
reconnects via `NWPathMonitor`. The reconnection is automatic. No action needed on the
receiver side; the 15 s `CONN_TIMEOUT` absorbs the gap.

### Extended keepalive mismatch
**Severity**: Low. **Status**: Backwards compatible by design.

Senders that don't support the extended format (BELABOX, Moblin, the Go
implementations) send bare or standard keepalives. This receiver handles all three
lengths. Senders that do support it (irlserver/srtla_send, `srtla-send-rs`) get
per-link telemetry; others don't. No functional impact on stream delivery.

### SRT auth-failure throttle
**Severity**: Low. **Status**: Upstream behaviour, deliberate.

Five downstream SRT handshake rejections from one source IP inside 60 s block new
registrations from that IP for 60 s (`AUTH_FAIL_*`). A sender reconnecting in a tight
loop with a wrong stream ID locks itself out, and every broadcaster sharing its public
IP. See `TROUBLESHOOTING.md`.

---

## 4. Compatibility Guarantees

The matrix in `tests/compat/matrix.yaml` locks the following:

1. **Tier 1 sender/receiver pairs must register and pass data** at the pinned
   versions. A CI failure in any blocking pair blocks merge.

2. **Extended keepalive is backwards compatible.** Any sender that sends a bare or
   standard keepalive works with this receiver. Any receiver that doesn't understand
   the extension works with the CERALIVE sender.

3. **Wire constants match `src/common.h` exactly.** No implementation-specific
   remapping. The hex values in this document are copied from that file and must stay
   in sync with it. Since `src/` is byte-identical to upstream, so are the constants.

4. **Timeouts are receiver-local.** `CONN_TIMEOUT` (15 s) and `GROUP_TIMEOUT` (30 s)
   are receiver-side tunables and do not affect wire compatibility. The CERALIVE
   sender runs the same 15 s link-liveness timeout so the two sides agree on when a
   link is dead.

5. **Nothing in this repo requires a peer to understand anything BELABOX srtla2 does
   not.** Extended keepalive and control padding are both additive.

---

## 5. Receiver-side libsrt behaviour (the srt-patch question)

`srtla_rec` itself links no libsrt: it is a pure UDP relay. The SRT behaviour that
matters for a bonded stream is the downstream SRT listener's (in the CERALIVE stack,
`irl-srt-server` on CERALIVE/srt). Two things were historically patched into that
libsrt to suit reordered, multi-path arrival: freezing the reorder-tolerance decay and
gating periodic NAK reports.

[`ADR-002`](adr/ADR-002-srt-patch-necessity.md) records the original A/B that showed
standard SRT options are a safe stand-in for the compile-time patch. Since then
CERALIVE/srt exposes the behaviours as socket options: `SRTO_SRTLAPATCHES = 118` (the
compat setter `irl-srt-server` uses), `SRTO_PERIODICNAKGATE = 119` (tri-state: `0` off,
`1` filter, `2` suppress) and `SRTO_REORDERFREEZE = 120`. Which periodic-NAK arm the
compat setter applies is decided by a pre-registered A/B on this repo's harness,
[`tests/compat/scenarios/ab-periodic-nak.yaml`](../tests/compat/scenarios/ab-periodic-nak.yaml),
using `reorder-stress.sh` as the instrument and `srt-sink` as the receiver stand-in.
`srt-sink` addresses those options by numeric id so it compiles against stock libsrt
headers; against a libsrt that lacks them it reports `unsupported` at runtime. Gate a
`REORDERFREEZE` arm on the *readback* value, not the banner.

---

## 6. ENABLE_ALGO_COMPARISON

`ENABLE_ALGO_COMPARISON` is defined in `src/receiver_config.h` with a default of `1`.
It runs the legacy receiver-only quality scoring in parallel with the connection-info
scoring and logs the two side by side. That is upstream's default and this repo does
not change it: `src/` is byte-identical to upstream, and the comparison output is what
the troubleshooting guide leans on. Changing it means changing it upstream.

---

## 7. Maintenance Policy

### Pin refresh
When a Tier 1 or Tier 2 implementation cuts a new release, update the `pin:` in
`tests/compat/matrix.yaml` and run the full blocking tier before merging. Do not update
pins in this document directly.

### Weekly drift job
`compat-matrix.yml`'s `upstream-drift` job (schedule only, `continue-on-error`) builds
the informational tier against each implementation's upstream HEAD instead of its pin
and runs those pairs against our receiver. It reports; it never changes a pin and never
opens a PR. Someone reads it.

### Adding a new implementation
1. Add it to `tests/compat/matrix.yaml` with tier, `pin:`, and language, and bump the
   `invariants:` pair counts.
2. Run at least one sender/receiver pair test against our receiver.
3. Document any quirks in section 3 of this file.
4. Open a PR with all of it together.

### Removing an implementation
Implementations that go unmaintained for 12+ months are downgraded to informational
and eventually removed from the matrix (`yannismate/srtla-rs` already went that way
and is no longer listed). Record the removal in section 3 if it had quirks worth
remembering.

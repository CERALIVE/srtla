# How SRTLA Works

This document explains the SRTLA protocol, the receiver's architecture, and the
algorithms behind it.

For quick-start usage, command reference, and build instructions, see the
[README](../README.md).

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Protocol](#protocol)
- [Extended Keepalive](#extended-keepalive)
- [Congestion Control](#congestion-control)
- [Connection Quality and Recovery](#connection-quality-and-recovery)
- [Observability](#observability)
- [Timeouts & Limits](#timeouts--limits)

---

## Overview

SRTLA (SRT Link Aggregation) sits between an SRT encoder and an SRT server and bonds
multiple network connections to increase bandwidth and reliability.

This repo is CERALIVE's hard fork of [irlserver/srtla](https://github.com/irlserver/srtla),
itself descended from [BELABOX/srtla](https://github.com/BELABOX/srtla). The receiver
source is byte-identical to upstream; CERALIVE adds only build policy, CI and tests.
The sender side of the pair is the Rust
[srtla-send-rs](https://github.com/CERALIVE/srtla-send-rs).

**Key capabilities:**
- **Bandwidth aggregation**: combine multiple connections for higher total throughput
- **Redundancy**: if one link fails, the others carry on
- **Adaptive load balancing**: better links get more traffic automatically

---

## Architecture

```
┌─────────────┐     ┌─────────────┐                ┌─────────────┐     ┌─────────────┐
│   Encoder   │────▶│ srtla_send  │═══════════════▶│ srtla_rec   │────▶│  SRT Server │
│   (SRT)     │     │  (Rust)     │  Multiple IPs  │   (this)    │     │             │
└─────────────┘     └─────────────┘                └─────────────┘     └─────────────┘
      │                   │                              │                    │
      │              Sender Side                    Receiver Side             │
      │                   │                              │                    │
      │   ┌───────────────┼───────────────┐              │                    │
      │   │               │               │              │                    │
      │   ▼               ▼               ▼              │                    │
      │ ┌─────┐       ┌─────┐       ┌─────┐              │                    │
      │ │usb0 │       │usb1 │       │wlan0│              │                    │
      │ │ LTE │       │ LTE │       │WiFi │              │                    │
      │ └─────┘       └─────┘       └─────┘              │                    │
      │    │             │             │                 │                    │
      │    └─────────────┼─────────────┘                 │                    │
      │                  │                               │                    │
      │                  ▼                               │                    │
      │         Internet (multiple paths)                │                    │
      │                  │                               │                    │
      │                  └───────────────────────────────┘                    │
      │                                                                       │
      └───────────────────────────────────────────────────────────────────────┘
                              End-to-end SRT connection
```

### `srtla_send` (Sender)

The sender lives in [srtla-send-rs](https://github.com/CERALIVE/srtla-send-rs). It:
1. Listens on a local port for SRT connections from the encoder
2. Creates one UDP socket per source IP (each bound to a different network)
3. Distributes outgoing SRT packets across all links
4. Tracks packet delivery via SRTLA ACKs and SRT NAKs
5. Adjusts which links get more traffic based on performance

The C `srtla_send` in `src/sender.cpp` is upstream's reference sender. It still builds
here (CI checks that it links) but it is not installed and CERALIVE does not run it.

### `srtla_rec` (Receiver)

The receiver:
1. Listens for incoming SRTLA connections on one UDP socket
2. Groups connections from the same sender (via the registration handshake)
3. Receives packets across all connections in `recvmmsg` batches and forwards them to
   the downstream SRT server
4. Broadcasts SRT ACK/NAK control packets to every connection in the group via
   `sendmmsg`, so a single bad link cannot stall retransmits
5. Sends SRTLA ACKs to help the sender with load distribution
6. Pads small control packets to 32 bytes (`src/protocol/pad_sendto.h`) to keep
   cellular NAT mappings warm
7. Throttles registrations per source IP after repeated SRT authentication failures
   (`AUTH_FAIL_*` in `src/receiver_config.h`)

The main loop is `epoll`-driven and single-threaded. The Prometheus endpoint is
answered from the same loop, so scraping costs no extra thread and takes no locks.

---

## Protocol

### Connection Registration

When the sender starts, it must register all its links with the receiver:

```
Sender                                  Receiver
   │                                       │
   │  ┌──────────────────────────────┐     │
   │  │ Link 1 (usb0)                │     │
   │──┼── REG1 [client_id] ──────────┼────▶│  "I want to start a session"
   │  │                              │     │
   │◀─┼── REG2 [full_id] ────────────┼─────│  "OK, here's the full session ID"
   │  │                              │     │
   │──┼── REG2 [full_id] ────────────┼────▶│  Link 1 joins the session
   │◀─┼── REG3 ──────────────────────┼─────│  "Link 1 confirmed"
   │  └──────────────────────────────┘     │
   │                                       │
   │  ┌──────────────────────────────┐     │
   │  │ Link 2 (usb1)                │     │
   │──┼── REG2 [full_id] ────────────┼────▶│  Link 2 joins the session
   │◀─┼── REG3 ──────────────────────┼─────│  "Link 2 confirmed"
   │  └──────────────────────────────┘     │
   │                                       │
   │  ┌──────────────────────────────┐     │
   │  │ Link 3 (wlan0)               │     │
   │──┼── REG2 [full_id] ────────────┼────▶│  Link 3 joins the session
   │◀─┼── REG3 ──────────────────────┼─────│  "Link 3 confirmed"
   │  └──────────────────────────────┘     │
   │                                       │
   │═══════ SRT Data (distributed) ═══════▶│
   │◀══════ SRT Data + SRTLA ACKs ════════│
   │                                       │
```

A group that completes REG1 but never forwards real SRT data is reaped after
`PENDING_GROUP_TIMEOUT` (5 s). That targets the "ghost" groups an unauthenticated REG1
flood leaves behind; a real broadcaster finishes REG2 and starts the SRT handshake in a
fraction of a second.

### Packet Types

Authoritative source: `src/common.h`.

| Type | Value | Length | Description |
|------|-------|--------|-------------|
| `SRTLA_TYPE_KEEPALIVE` | 0x9000 | 2 / 10 / 38 bytes | NAT keepalive, echoed back by the receiver |
| `SRTLA_TYPE_ACK` | 0x9100 | 4 + 4 × count | Batch ACK for congestion control |
| `SRTLA_TYPE_REG1` | 0x9200 | 258 bytes | Initial group registration (client_id) |
| `SRTLA_TYPE_REG2` | 0x9201 | 258 bytes | Registration response/confirmation (full_id) |
| `SRTLA_TYPE_REG3` | 0x9202 | 2 bytes | Connection established |
| `SRTLA_TYPE_REG_ERR` | 0x9210 | 2 bytes | Registration error |
| `SRTLA_TYPE_REG_NGP` | 0x9211 | 2 bytes | No group found (triggers re-registration) |
| `SRTLA_TYPE_REG_NAK` | 0x9212 | 2 bytes | Defined in `common.h`; the receiver never emits it |

### Session ID

The session ID is 256 bytes:
- First 128 bytes: generated by the sender (client_id)
- Last 128 bytes: generated by the receiver (server_id)

This means the sender can identify its own sessions, the receiver can verify sessions
it created, and connections are hard to spoof.

### NAT Keepalive

Mobile networks use NAT with short timeouts. The sender emits a keepalive after about
one second of idle time and the receiver echoes it:

```
Sender                     NAT                      Receiver
   │                        │                           │
   │ ─── KEEPALIVE ────────▶│ ─── KEEPALIVE ──────────▶│
   │                        │                           │
   │◀─── KEEPALIVE ─────────│◀─── KEEPALIVE ───────────│
   │                        │                           │
   │        (NAT mapping refreshed)                     │
```

The receiver pads every control reply smaller than 32 bytes up to 32
(`pad_sendto`), because some carrier NATs drop tiny UDP frames instead of refreshing
the mapping.

---

## Extended Keepalive

Senders that support it emit an extended keepalive: a 38-byte `0x9000` packet with
magic `0xC01F` at bytes 10-11 and version `0x0001`, carrying `connection_info_t`
(per-link RTT, NAK count, congestion window, in-flight packets, bitrate). Both
irlserver's Rust sender and CERALIVE's `srtla-send-rs` send it.

The receiver latches `sender_supports_extended_keepalives` on the first such packet
(`ConnectionStats` in `src/receiver_config.h`) and feeds the telemetry into the quality
evaluator while it is fresh (`KEEPALIVE_STALENESS_THRESHOLD`, 2 s).

Senders that only emit the bare 2-byte or standard 10-byte keepalive (BELABOX, Moblin,
the Go implementations) work exactly as before: the receiver falls back to its own
receiver-side observations. The `ext-ka-probe` helper in `tests/compat/` sends a real
extended keepalive so the telemetry path can be exercised in the harness without a
full sender.

For the ecosystem picture, see [COMPATIBILITY.md](COMPATIBILITY.md).

---

## Congestion Control

SRTLA uses a window-based algorithm on the sender to distribute packets across links.
The receiver's job is to feed that algorithm honest, timely signals.

### Link Score (sender side)

Each link has a "window" that represents its capacity. The sender selects links using:

```
score = window / (in_flight_packets + 1)
```

The link with the highest score is selected for each packet. SRTLA ACKs grow the
window slowly, SRT NAKs shrink it fast, so lossy links lose traffic and recover slowly.
The exact constants and the selection policy belong to the sender; see the
`srtla-send-rs` documentation.

### ACK Delivery (receiver side)

SRTLA ACKs are sent unconditionally every `RECV_ACK_INT` (10) received packets.
Earlier BELABOX-derived builds delayed ACKs as a back-pressure mechanism, but that
created a feedback loop with senders that tie SRT window growth to ACK timing:
throttled ACKs slowed window growth, the link looked worse, more throttling kicked in,
and audio glitches followed. Upstream removed the throttling; this fork inherits that.

SRT-level ACK and NAK control packets from the downstream SRT server are broadcast to
every connection in the group (`src/protocol/srt_handler.cpp`), so a retransmit
request reaches the sender even if the link that carried the lost packet is stalled.

---

## Connection Quality and Recovery

### Quality Weights

Every `CONN_QUALITY_EVAL_PERIOD` (5 s) the receiver assigns each connection a weight
level: `WEIGHT_FULL` (100 %), `WEIGHT_EXCELLENT` (85 %), `WEIGHT_DEGRADED` (70 %),
`WEIGHT_FAIR` (55 %), `WEIGHT_POOR` (40 %) or `WEIGHT_CRITICAL` (10 %). Values are in
`src/receiver_config.h`.

Two evaluation paths exist (`src/quality/quality_evaluator.cpp`):

- **Connection-info path**: when fresh extended-keepalive telemetry is available, the
  evaluator scores RTT (thresholds `RTT_THRESHOLD_*`, variance
  `RTT_VARIANCE_THRESHOLD`), sender-reported NAK rate (`NAK_RATE_*`), window
  utilisation and the bitrate discrepancy between what the sender reports and what the
  receiver measures.
- **Receiver-only path**: otherwise it falls back to bandwidth performance against the
  group's median (or `MIN_ACCEPTABLE_TOTAL_BANDWIDTH_KBPS` for poor links) and packet
  loss.

`ENABLE_ALGO_COMPARISON` (default `1`) additionally runs the legacy receiver-only
scoring in parallel on every evaluation and logs the two side by side (`[COMPARISON]`
lines at info level when weights change, `[ALGO_CMP]` at verbose level on keepalives).
Only the primary path drives the weight; the legacy numbers are for comparison.

New connections get `CONNECTION_GRACE_PERIOD` (10 s) before penalties accumulate.

### Recovery Mode

A connection that shows signs of life after being marked inactive enters recovery mode
and is probed with keepalives every `KEEPALIVE_PERIOD` (1 s) for up to
`RECOVERY_CHANCE_PERIOD` (5 s). If it stays stable it is fully reactivated; otherwise
the attempt is abandoned and the connection is dropped. The cadence of those probes is
the subject of a pre-registered A/B on the compat harness
(`tests/compat/scenarios/ab-keepalive-cadence.yaml`); the shipped behaviour stays
upstream's until that measurement says otherwise.

---

## Observability

`srtla_rec` exports Prometheus text over HTTP when started with `--metrics_port`. It
always exports traffic counters, registration outcomes (with rejection reasons), group
teardowns, auth throttling, NAK handling, recovery and send-error counters, and live
gauges for groups and connections. `--metrics_detail` adds per-connection series
(`srtla_conn_*`: bytes, packets, loss, weight, error points, RTT, window, in-flight,
sender bitrate, idle time) labelled by group and remote address.
`docs/grafana-dashboard.json` covers every exported metric.

Divide `srtla_packets_received_total` by `srtla_recv_batches_total` to get the receive
loop fill ratio; a climbing ratio means `recvmmsg()` is returning fuller batches as the
loop nears saturation.

The receiver also writes `/tmp/srtla-group-<PORT>` files listing the client addresses
of each active group (`SRT_SOCKET_INFO_PREFIX`).

Log verbosity is `--verbose` (info) and `--debug`. Weight changes are logged at info
level with the `[COMPARISON]` side-by-side; the per-evaluation detail (evaluation
mode, bandwidth, loss, error points) is at debug level.

---

## Timeouts & Limits

All values live in `src/receiver_config.h`.

| Parameter | Value | Description |
|-----------|-------|-------------|
| `MAX_CONNS_PER_GROUP` | 16 | Maximum links per streaming session |
| `MAX_GROUPS` | 200 | Maximum concurrent streaming sessions |
| `CLEANUP_PERIOD` | 3 s | Housekeeping interval |
| `CONN_TIMEOUT` | 15 s | Per-connection inactivity timeout |
| `GROUP_TIMEOUT` | 30 s | Idle group reap timeout |
| `PENDING_GROUP_TIMEOUT` | 5 s | Reap a group that registered but never sent SRT data |
| `RECV_ACK_INT` | 10 | Send an SRTLA ACK every N data packets |
| `KEEPALIVE_PERIOD` | 1 s | Keepalive interval during connection recovery |
| `RECOVERY_CHANCE_PERIOD` | 5 s | Window for a connection to recover before abandonment |
| `CONN_QUALITY_EVAL_PERIOD` | 5 s | Interval for evaluating per-connection quality |
| `CONNECTION_GRACE_PERIOD` | 10 s | Grace period before new connections accumulate penalties |
| `KEEPALIVE_STALENESS_THRESHOLD` | 2 s | Sender telemetry older than this is ignored |
| `AUTH_FAIL_THRESHOLD` / `_WINDOW` / `_COOLDOWN` | 5 / 60 s / 60 s | Per-IP SRT auth-failure throttle |

The 15 s `CONN_TIMEOUT` matters to the sender too: `srtla-send-rs` runs the same
15 s link-liveness timeout so that a link mid radio-stall is not re-registered by the
sender while the receiver still holds it.

### Socket Buffers

`SEND_BUF_SIZE` and `RECV_BUF_SIZE` (`src/common.h`) are both 100 MiB, requested via
`SO_SNDBUF`/`SO_RCVBUF`. The kernel clamps them to `net.core.wmem_max` /
`net.core.rmem_max`; see [NETWORK_SETUP.md](NETWORK_SETUP.md) for the sysctl values.

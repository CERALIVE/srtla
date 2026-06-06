# How SRTLA Works

This document explains the SRTLA protocol, architecture, and internal algorithms.

For quick-start usage, command reference, and build instructions, see the [README](../README.md).

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Protocol](#protocol)
- [Congestion Control](#congestion-control)
- [Connection Recovery](#connection-recovery)
- [Timeouts & Limits](#timeouts--limits)

---

## Overview

SRTLA (SRT Link Aggregation) is a protocol that sits between an SRT encoder and SRT server, bonding multiple network connections to increase bandwidth and reliability.

This implementation is a fork of [BELABOX/srtla](https://github.com/BELABOX/srtla) with contributions from IRLToolkit, IRLServer, OpenIRL, and CeraLive. The `irlserver/main` upstream was merged in full (commit `aa66a88`), bringing upstream-aligned connection handling, ACK-throttling removal, and quality evaluation enhancements.

**Key capabilities:**
- **Bandwidth aggregation**: Combine multiple connections for higher total throughput
- **Redundancy**: If one link fails, others continue
- **Adaptive load balancing**: Better links get more traffic automatically

---

## Architecture

```
┌─────────────┐     ┌─────────────┐                ┌─────────────┐     ┌─────────────┐
│   Encoder   │────▶│ srtla_send  │═══════════════▶│ srtla_rec   │────▶│  SRT Server │
│   (SRT)     │     │             │  Multiple IPs  │             │     │             │
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

The sender:
1. Listens on a local port for SRT connections from the encoder
2. Creates one UDP socket per source IP (each bound to a different network)
3. Distributes outgoing SRT packets across all links
4. Tracks packet delivery via SRTLA ACKs and SRT NAKs
5. Adjusts which links get more traffic based on performance

### `srtla_rec` (Receiver)

The receiver:
1. Listens for incoming SRTLA connections
2. Groups connections from the same sender (via registration handshake)
3. Receives packets across all connections via `recvmmsg` batches and forwards to downstream SRT server
4. Broadcasts SRT ACK/NAK control packets to every connection in the group via `sendmmsg`, so a single bad link cannot stall retransmits
5. Sends SRTLA ACKs to help sender with load distribution
6. Pads small control packets to 32 bytes (`pad_sendto`) to keep cellular NAT mappings warm

---

## Protocol

### Connection Registration

When the sender starts, it must register all its links with the receiver:

```
Sender                                  Receiver
   │                                       │
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

### Packet Types

| Type | Value | Length | Description |
|------|-------|--------|-------------|
| `SRTLA_TYPE_KEEPALIVE` | 0x9000 | 2 bytes | NAT keepalive, echoed back by receiver |
| `SRTLA_TYPE_ACK` | 0x9100 | variable | Batch ACK for congestion control |
| `SRTLA_TYPE_REG1` | 0x9200 | 258 bytes | Initial group registration (client_id) |
| `SRTLA_TYPE_REG2` | 0x9201 | 258 bytes | Registration response/confirmation (full_id) |
| `SRTLA_TYPE_REG3` | 0x9202 | 2 bytes | Connection established |
| `SRTLA_TYPE_REG_ERR` | 0x9210 | 2 bytes | Registration error |
| `SRTLA_TYPE_REG_NGP` | 0x9211 | 2 bytes | No group found (triggers re-registration) |

### Session ID

The session ID is 256 bytes:
- First 128 bytes: Generated by sender (client_id)
- Last 128 bytes: Generated by receiver (server_id)

This ensures:
- Sender can identify its own sessions
- Receiver can verify sessions it created
- Hard to spoof connections

### NAT Keepalive

Mobile networks use NAT with short timeouts. SRTLA sends keepalive packets every ~1 second of idle time:

```
Sender                     NAT                      Receiver
   │                        │                           │
   │ ─── KEEPALIVE ────────▶│ ─── KEEPALIVE ──────────▶│
   │                        │                           │
   │◀─── KEEPALIVE ─────────│◀─── KEEPALIVE ───────────│
   │                        │                           │
   │        (NAT mapping refreshed)                     │
```

---

## Congestion Control

SRTLA uses a window-based algorithm on the sender to distribute packets across links.

### Link Score

Each link has a "window" that represents its capacity. The sender selects links using:

```
score = window / (in_flight_packets + 1)
```

The link with the highest score is selected for each packet.

### Window Adjustment

| Event | Action |
|-------|--------|
| SRTLA ACK received | `window += 1` (slow increase) |
| In-flight < window | `window += 30` (faster increase) |
| SRT NAK received | `window -= 100` (fast decrease) |

### Parameters

| Parameter | Value | Meaning |
|-----------|-------|---------|
| `WINDOW_MIN` | 1,000 | Minimum window (link nearly disabled) |
| `WINDOW_DEF` | 20,000 | Starting window for new links |
| `WINDOW_MAX` | 60,000 | Maximum window (best performing link) |

### Behavior

A link with a large window and few in-flight packets scores highest and receives the most traffic. A link with a small window (due to packet loss) scores lower and gets fewer packets. This naturally:
- Sends more through fast/reliable links
- Avoids overloading slow/lossy links
- Recovers slowly after packet loss (prevents oscillation)

### ACK Delivery

SRTLA ACKs are sent unconditionally every `RECV_ACK_INT` (10) packets. Earlier builds delayed ACKs as a back-pressure mechanism, but that created a feedback loop with senders that tie SRT window growth to ACK timing: throttled ACKs slowed window growth, the link looked worse, more throttling kicked in, and audio glitches followed. The `irlserver` upstream removed this throttling; CeraLive aligned with that decision at the merge.

---

## Connection Recovery

Connections with temporary problems are not disabled outright. The receiver tracks per-connection quality and applies a graduated response:

### Quality Weights

The receiver assigns each connection a weight level that influences how much traffic it receives. Levels range from `WEIGHT_FULL` (optimal) down through `WEIGHT_EXCELLENT`, `WEIGHT_DEGRADED`, `WEIGHT_FAIR`, `WEIGHT_POOR`, and `WEIGHT_CRITICAL` (critically impaired). See `src/receiver_config.h` for the exact weight values.

Quality is assessed by bandwidth performance, packet loss, and dynamic bandwidth evaluation against median/minimum thresholds. New connections have a grace period (`CONNECTION_GRACE_PERIOD`) before penalties apply.

### Recovery Mode

Connections showing signs of recovery enter a recovery mode and receive more frequent keepalive packets for `RECOVERY_CHANCE_PERIOD`. After successful recovery they are fully reactivated; if recovery fails within that window, the connection is abandoned.

---

## Timeouts & Limits

### Sender

| Parameter | Description |
|-----------|-------------|
| `CONN_TIMEOUT` | Link considered dead if no response |
| `REG2_TIMEOUT` | Wait for REG2 after sending REG1 |
| `REG3_TIMEOUT` | Wait for REG3 after sending REG2 |
| `GLOBAL_TIMEOUT` | Exit if no links connect within this window |
| `IDLE_TIME` | Send keepalive after this idle time |
| `HOUSEKEEPING_INT` | Check connection health interval |

### Receiver

Post-merge timeouts are tuned for cellular resilience. See `src/receiver_config.h` for current values.

| Parameter | Description |
|-----------|-------------|
| `MAX_CONNS_PER_GROUP` | Maximum links per streaming session |
| `MAX_GROUPS` | Maximum concurrent streaming sessions |
| `CONN_TIMEOUT` | Per-connection inactivity timeout (cellular-resilient) |
| `GROUP_TIMEOUT` | Idle group reap timeout (cellular-resilient; longer than pre-merge) |
| `RECV_ACK_INT` | Send SRTLA ACK every N data packets |
| `KEEPALIVE_PERIOD` | Keepalive interval during connection recovery |
| `RECOVERY_CHANCE_PERIOD` | Window for a connection to recover before abandonment |
| `CONN_QUALITY_EVAL_PERIOD` | Interval for evaluating per-connection quality |
| `CONNECTION_GRACE_PERIOD` | Grace period before new connections accumulate penalties |

### Socket Buffers

| Buffer | Why |
|--------|-----|
| `SEND_BUF_SIZE` | Handle bursts without dropping |
| `RECV_BUF_SIZE` | Buffer incoming packets during processing |

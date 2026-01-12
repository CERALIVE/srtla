# How SRTLA Works

This document explains the SRTLA protocol, architecture, and internal algorithms.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Protocol](#protocol)
- [Congestion Control](#congestion-control)
- [Timeouts & Limits](#timeouts--limits)

---

## Overview

SRTLA (SRT Link Aggregation) is a protocol that sits between an SRT encoder and SRT server, bonding multiple network connections to increase bandwidth and reliability.

**Key capabilities:**
- **Bandwidth aggregation**: Combine 3× 5Mbps connections into ~15Mbps
- **Redundancy**: If one link fails, others continue
- **Adaptive load balancing**: Better links get more traffic

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
3. Reassembles packets and forwards to downstream SRT server
4. Sends SRTLA ACKs to help sender with congestion control

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

SRTLA uses a window-based algorithm to distribute packets across links.

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

```
Good link (low loss):          Poor link (high loss):
  window: 55,000                 window: 5,000
  in_flight: 10                  in_flight: 2
  score: 5,000                   score: 1,666
  
  → Gets 3× more packets         → Gets fewer packets
```

This naturally:
- Sends more through fast/reliable links
- Avoids overloading slow/lossy links
- Recovers slowly after packet loss (prevents oscillation)

---

## Timeouts & Limits

### Sender

| Parameter | Value | Description |
|-----------|-------|-------------|
| `CONN_TIMEOUT` | 4 seconds | Link considered dead if no response |
| `REG2_TIMEOUT` | 4 seconds | Wait for REG2 after sending REG1 |
| `REG3_TIMEOUT` | 4 seconds | Wait for REG3 after sending REG2 |
| `GLOBAL_TIMEOUT` | 10 seconds | Exit if no links connect |
| `IDLE_TIME` | 1 second | Send keepalive after this idle time |
| `HOUSEKEEPING_INT` | 1000 ms | Check connection health interval |

### Receiver

| Parameter | Value | Description |
|-----------|-------|-------------|
| `MAX_CONNS_PER_GROUP` | 16 | Maximum links per streaming session |
| `MAX_GROUPS` | 200 | Maximum concurrent streaming sessions |
| `CONN_TIMEOUT` | 10 seconds | Remove inactive links |
| `GROUP_TIMEOUT` | 10 seconds | Remove empty groups |
| `CLEANUP_PERIOD` | 3 seconds | Garbage collection interval |
| `RECV_ACK_INT` | 10 packets | Send SRTLA ACK every N packets |

### Socket Buffers

| Buffer | Size | Why |
|--------|------|-----|
| `SEND_BUF_SIZE` | 32 MB | Handle bursts without dropping |
| `RECV_BUF_SIZE` | 32 MB | Buffer incoming packets during processing |

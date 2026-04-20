# SRTLA - SRT Link Aggregation

SRTLA bonds multiple network connections together for live video streaming, providing increased bandwidth and redundancy.

This is a fork of the [BELABOX SRTLA project](https://github.com/BELABOX/srtla), with contributions from IRLToolkit, IRLServer, OpenIRL, and CeraLive.

## What It Does

```
┌─────────────┐     ┌─────────────┐                ┌─────────────┐     ┌─────────────┐
│   Encoder   │────▶│ srtla_send  │═══════════════▶│ srtla_rec   │────▶│  SRT Server │
│   (SRT)     │     │             │  Multiple IPs  │             │     │             │
└─────────────┘     └─────────────┘                └─────────────┘     └─────────────┘
                          │
                    ┌─────┴─────┐
                    ▼     ▼     ▼
                  LTE   LTE   WiFi
                   1     2
```

- **Combine bandwidth**: 3× 5Mbps connections → ~15Mbps total
- **Redundancy**: One link fails, others continue
- **Adaptive**: Better links automatically get more traffic

## Features

- Link aggregation across multiple network connections
- Connection groups with per-connection quality tracking
- Cellular-resilient timeouts and NAT keepalive padding
- Broadcast ACK/NAK delivery across all connections in a group
- Batch packet I/O (`recvmmsg`/`sendmmsg`) for low syscall overhead
- Connection-recovery mode for temporary network issues
- Comprehensive docs (network setup, troubleshooting, protocol)
- TypeScript bindings for `srtla_send` / `srtla_rec`

## Quick Start

### Receiver (Server Side)

```bash
srtla_rec --srtla_port 5000 --srt_hostname 127.0.0.1 --srt_port 5001
```

### Sender (Encoder Side)

**With CeraUI** (recommended): The IP list is managed automatically. CeraUI detects network interfaces, writes the IP file, and signals `srtla_send` when interfaces change.

**Standalone usage**:

1. Create IP list file:
   ```bash
   echo "10.0.0.10" > /tmp/srtla_ips   # usb0 IP
   echo "10.0.1.10" >> /tmp/srtla_ips  # usb1 IP  
   echo "192.168.1.50" >> /tmp/srtla_ips  # wlan0 IP
   ```

2. Start sender:
   ```bash
   srtla_send 5000 relay.example.com 5001 /tmp/srtla_ips
   ```

3. Configure encoder to send SRT to `localhost:5000`

4. When interfaces change, update the file and signal reload:
   ```bash
   kill -HUP $(pidof srtla_send)
   ```

### Critical: Network Setup Required!

**SRTLA will NOT work correctly without source-based routing!**

Without it, all traffic goes through one interface regardless of which source IP is used.

See **[Network Setup Guide](docs/NETWORK_SETUP.md)** for step-by-step instructions.

## Building

```bash
mkdir build && cd build
cmake ..
make
sudo make install
```

**Dependencies:**
- CMake 3.16+
- C++17 compiler
- spdlog (fetched automatically via CMake)
- argparse (included in deps/)

## Documentation

| Document | Description |
|----------|-------------|
| [Network Setup](docs/NETWORK_SETUP.md) | **Start here!** Routing config, IP list management |
| [How It Works](docs/HOW_IT_WORKS.md) | Protocol details, architecture, congestion control |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Common issues and solutions |
| [Connection Info Comparison](docs/connection-info-comparison.md) | Connection metrics and comparison |
| [Keepalive Improvements](docs/keepalive-improvements.md) | Extended keepalive fix documentation |

> **Note**: If using CeraUI, the IP list (`/tmp/srtla_ips`) is managed automatically. See [Managing the IP List](docs/NETWORK_SETUP.md#managing-the-ip-list) for details.

## Command Reference

### srtla_send

```bash
srtla_send <listen_port> <srtla_host> <srtla_port> <ips_file> [--verbose]
```

| Argument | Description | Default |
|----------|-------------|---------|
| `listen_port` | Port for local SRT encoder | 5000 |
| `srtla_host` | Remote SRTLA receiver hostname | 127.0.0.1 |
| `srtla_port` | Remote SRTLA receiver port | 5001 |
| `ips_file` | File with source IPs (one per line) | /tmp/srtla_ips |
| `--verbose` | Enable debug logging | off |

**Signals:**
- `SIGHUP`: Reload IP list without restart

### srtla_rec

```bash
srtla_rec --srtla_port <port> --srt_hostname <host> --srt_port <port> [--verbose] [--debug]
```

| Argument | Description | Default |
|----------|-------------|---------|
| `--srtla_port` | Listen port for SRTLA connections | 5000 |
| `--srt_hostname` | Downstream SRT server | 127.0.0.1 |
| `--srt_port` | Downstream SRT port | 4001 |
| `--verbose` | Enable verbose logging | off |
| `--debug` | Enable debug logging | off |

## Technical Details

### How It Works

1. `srtla_rec` creates a UDP socket for incoming SRTLA connections.
2. Clients register with `srtla_rec` and create connection groups.
3. Multiple connections can be added to a group.
4. Data is received across all connections (via `recvmmsg` batches) and
   forwarded to the SRT server.
5. SRT control packets (ACK and NAK) are broadcast to every connection
   in the group via `sendmmsg` so a single bad link cannot stall
   retransmits. SRT handshakes go to the originating link only.
6. Small control packets are padded to 32 bytes via `pad_sendto` to
   keep cellular NAT mappings warm.
7. Inactive connections and groups are automatically cleaned up after
   `CONN_TIMEOUT` / `GROUP_TIMEOUT` seconds.

### Two-phase Registration Process

- Sender (conn 0): `SRTLA_REG1` (contains sender-generated random ID)
- Receiver: `SRTLA_REG2` (contains full ID with receiver-generated values)
- Sender (conn 0): `SRTLA_REG2` (with full ID)
- Receiver: `SRTLA_REG3`
- Additional connections follow a similar pattern

### Error Handling

The receiver can send error responses:
- `SRTLA_REG_ERR`: Operation temporarily failed
- `SRTLA_REG_NGP`: Invalid ID, group must be re-registered

## Load Balancing and Recovery

### How load is distributed across links

Load distribution is driven by the **sender** (`srtla_send`), which scores
each connection on window size and in-flight packets and prefers better
links automatically. The receiver supports this by:

- **Broadcasting ACK/NAK control packets** to every connection in a group,
  so loss on the most-recent connection cannot stall retransmits.
- **Tracking per-connection quality** (`weight_percent`, error points)
  for telemetry and operator visibility.
- **Padding small control packets** to 32 bytes via `pad_sendto`, so
  cellular NAT mappings remain warm.

> **Why no ACK throttling?** Earlier CeraLive builds delayed SRTLA ACKs as
> a back-pressure mechanism. That created a positive feedback loop with
> senders (notably Moblin) that tie SRT window growth to ACK timing —
> throttled ACKs slowed window growth, the link looked worse, more
> throttling kicked in, audio glitches followed. Upstream removed the
> throttling and CeraLive aligned with that decision; SRTLA ACKs are now
> sent unconditionally every `RECV_ACK_INT` (10) packets.

### Connection Recovery

Connections with temporary problems are not disabled outright:

- Connections showing signs of recovery enter a "recovery mode".
- Those connections receive more frequent keepalive packets for a set
  period (`RECOVERY_CHANCE_PERIOD`, 5 seconds).
- After successful recovery they are fully reactivated.
- Recovery attempts are abandoned after that period if unsuccessful.

### Connection Quality Assessment

Connection quality is assessed by:

- **Bandwidth performance** (actual vs expected throughput).
- **Packet loss** (higher loss -> more error points).
- **Dynamic bandwidth evaluation** against median / minimum thresholds.
- **Grace period** (`CONNECTION_GRACE_PERIOD`, 10 s) before new
  connections accumulate penalties.

Weight levels:
- 100% (`WEIGHT_FULL`): Optimal connection.
- 85% (`WEIGHT_EXCELLENT`): Excellent connection.
- 70% (`WEIGHT_DEGRADED`): Slightly impaired.
- 55% (`WEIGHT_FAIR`): Fair.
- 40% (`WEIGHT_POOR`): Severely impaired.
- 10% (`WEIGHT_CRITICAL`): Critically impaired.

### Configuration Parameters

Receiver tunables (all live in `src/receiver_config.h`):

| Parameter | Default | Description |
|-----------|---------|-------------|
| `KEEPALIVE_PERIOD` | 1 s | Interval for keepalive packets during recovery |
| `RECOVERY_CHANCE_PERIOD` | 5 s | Period for connection recovery attempt |
| `CONN_QUALITY_EVAL_PERIOD` | 5 s | Interval for evaluating connection quality |
| `RECV_ACK_INT` | 10 packets | SRTLA ACK is emitted every N data packets |
| `GROUP_TIMEOUT` | 30 s | Idle group is reaped after this period (cellular-resilient) |
| `CONN_TIMEOUT` | 15 s | Per-connection inactivity timeout (cellular-resilient) |
| `MIN_ACCEPTABLE_TOTAL_BANDWIDTH_KBPS` | 1000 | Minimum total bandwidth for acceptable streaming |
| `GOOD_CONNECTION_THRESHOLD` | 50% | Threshold for a "good" connection |
| `CONNECTION_GRACE_PERIOD` | 10 s | Grace period before applying penalties |

## Socket Information

srtla_rec creates information files about active connections under `/tmp/srtla-group-[PORT]`. These files contain the client IP addresses connected to a specific socket.

## Setup Checklist

- [ ] Routing tables added to `/etc/iproute2/rt_tables`
- [ ] DHCP hook installed for USB/Ethernet modems
- [ ] NetworkManager dispatcher installed for WiFi
- [ ] Public DNS configured
- [ ] UDP buffer sizes increased (`sysctl`)
- [ ] Firewall allows UDP traffic
- [ ] Source IPs file created
- [ ] Verified with `ip route get ... from <source_ip>`

## Support the Project

If you find SRTLA useful, consider supporting CeraLive development:

- [Ko-fi](https://ko-fi.com/andrescera)
- [PayPal](https://www.paypal.com/donate/?business=7KKQS9KBSAMNE&no_recurring=0&item_name=CERALIVE+Development+Support&currency_code=USD)

## License

GNU Affero General Public License v3.0 (AGPL-3.0)

Copyright (C) 2020-2021 BELABOX project  
Copyright (C) 2024 IRLToolkit Inc.  
Copyright (C) 2024 OpenIRL  
Copyright (C) 2025 IRLServer.com  
Copyright (C) 2025 CeraLive

You can use, modify, and distribute this code according to the terms of the AGPL-3.0.

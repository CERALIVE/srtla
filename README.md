# SRTLA - SRT Link Aggregation

SRTLA bonds multiple network connections together for live video streaming, providing increased bandwidth and redundancy.

This is a fork of the [BELABOX SRTLA project](https://github.com/BELABOX/srtla), with contributions from IRLToolkit, IRLServer, and CeraLive.

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

### ⚠️ Critical: Network Setup Required!

**SRTLA will NOT work correctly without source-based routing!**

Without it, all traffic goes through one interface regardless of which source IP is used.

See **[Network Setup Guide](docs/NETWORK_SETUP.md)** for step-by-step instructions.

## Documentation

| Document | Description |
|----------|-------------|
| [Network Setup](docs/NETWORK_SETUP.md) | **Start here!** Routing config, IP list management |
| [How It Works](docs/HOW_IT_WORKS.md) | Protocol details, architecture, congestion control |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Common issues and solutions |

> **Note**: If using CeraUI, the IP list (`/tmp/srtla_ips`) is managed automatically. See [Managing the IP List](docs/NETWORK_SETUP.md#managing-the-ip-list) for details.

## Building

```bash
mkdir build && cd build
cmake ..
make
sudo make install
```

**Dependencies:**
- CMake 3.16+
- spdlog
- C++17 compiler

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
srtla_rec --srtla_port <port> --srt_hostname <host> --srt_port <port> [--verbose]
```

| Argument | Description | Default |
|----------|-------------|---------|
| `--srtla_port` | Listen port for SRTLA connections | 5000 |
| `--srt_hostname` | Downstream SRT server | 127.0.0.1 |
| `--srt_port` | Downstream SRT port | 5001 |
| `--verbose` | Enable debug logging | off |

## Setup Checklist

- [ ] Routing tables added to `/etc/iproute2/rt_tables`
- [ ] DHCP hook installed for USB/Ethernet modems
- [ ] NetworkManager dispatcher installed for WiFi
- [ ] Public DNS configured
- [ ] UDP buffer sizes increased (`sysctl`)
- [ ] Firewall allows UDP traffic
- [ ] Source IPs file created
- [ ] Verified with `ip route get ... from <source_ip>`

## License

GNU Affero General Public License v3.0 (AGPL-3.0)

Copyright (C) 2020-2021 BELABOX project  
Copyright (C) 2024 IRLToolkit Inc.  
Copyright (C) 2025 IRLServer.com  
Copyright (C) 2025 CeraLive

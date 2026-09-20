# SRTLA Troubleshooting Guide

Common issues and how to diagnose them. For protocol internals and the connection model,
see [HOW_IT_WORKS.md](HOW_IT_WORKS.md).

`srtla_send` below is the Rust [srtla-send-rs](https://github.com/CERALIVE/srtla-send-rs)
sender; `srtla_rec` is the receiver built from this repo.

## Table of Contents

- [No Connections Established](#no-connections-established)
- [Only One Link Working](#only-one-link-working)
- [Connections Keep Dropping](#connections-keep-dropping)
- [High Packet Loss](#high-packet-loss)
- [Stream Stuttering](#stream-stuttering)
- [Link Quality Looks Wrong](#link-quality-looks-wrong)
- [Receiver Rejecting Registrations](#receiver-rejecting-registrations)
- [Debugging Tools](#debugging-tools)

---

## No Connections Established

### Symptoms
- `srtla_send` logs that no uplink could be established, or keeps retrying REG1
- Encoder can't connect or times out

### Diagnosis

**1. Check if receiver is reachable:**
```bash
nc -u -v <receiver_ip> <srtla_port>
```

**2. Check firewall on receiver:**
```bash
# On receiver
sudo iptables -L -n | grep <srtla_port>

# Should show ACCEPT, if not:
sudo iptables -A INPUT -p udp --dport <srtla_port> -j ACCEPT
```

**3. Verify source IPs file:**
```bash
cat /tmp/srtla_ips

# Should show one IP per line, each assigned to an interface:
ip addr | grep "inet "
```

**4. Check sender can bind to IPs:**
```bash
# For each IP in srtla_ips, verify it exists:
ip addr show | grep "10.0.0.10"  # Replace with your IP
```

### Solutions

| Problem | Fix |
|---------|-----|
| Firewall blocking | Open UDP port on receiver |
| IP not assigned to interface | Wait for DHCP or check modem |
| Wrong receiver address | Verify hostname resolves correctly |
| Receiver throttling the source IP | See [Receiver Rejecting Registrations](#receiver-rejecting-registrations) |

---

## Only One Link Working

### Symptoms
- SRTLA connects but only uses one modem
- Other modems have IPs but no traffic

### This is the #1 issue - Missing Source Routing!

**Diagnosis:**

```bash
# Check policy rules exist
ip rule show

# Should show one rule per IP:
# 100:    from 10.0.0.10 lookup usb0
# 101:    from 10.0.1.10 lookup usb1
```

If you only see:
```
0:      from all lookup local
32766:  from all lookup main
32767:  from all lookup default
```

**Source routing is NOT configured!**

**Test which interface each IP actually uses:**
```bash
ip route get 8.8.8.8 from 10.0.0.10
ip route get 8.8.8.8 from 10.0.1.10
```

If both show the same interface, routing is broken.

### Solutions

1. **Check routing tables exist:**
   ```bash
   cat /etc/iproute2/rt_tables | grep usb
   ```
   If empty, add them (see [Network Setup](NETWORK_SETUP.md#step-1-create-routing-tables))

2. **Check DHCP hook is executable:**
   ```bash
   ls -la /etc/dhcp/dhclient-exit-hooks.d/srtla-source-routing
   # Should show: -rwxr-xr-x
   ```

3. **Check hook is running:**
   ```bash
   grep "SRTLA" /var/log/syslog
   ```
   Should show messages like "SRTLA: usb0 (10.0.0.10) → table usb0"

4. **Manually trigger DHCP:**
   ```bash
   sudo dhclient -v usb0
   ```

---

## Connections Keep Dropping

### Symptoms
- Links connect then disconnect every 30-60 seconds
- Logs show: "connection failed, attempting to reconnect"

### Causes

**1. NAT timeout (most common)**

Mobile carriers timeout NAT mappings after 30-60 seconds of inactivity.

Check if keepalives are working:
```bash
# Run srtla_send with --verbose (debug logging)
srtla_send ... --verbose 2>&1 | grep -i keepalive
```

Should show periodic keepalive sends and their echoes. On the receiver side, a keepalive
that never gets echoed is the signature of a NAT mapping that was dropped mid-stream;
`--debug` on `srtla_rec` logs every keepalive it answers.

**2. Carrier killing idle connections**

Some carriers aggressively terminate UDP connections. Solutions:
- Use a VPN to tunnel traffic
- Try a different APN
- Request a static/public IP from carrier

**3. Modem disconnecting**

Check if modem is losing connection:
```bash
watch -n 1 "ip addr show usb0"
```

If IP disappears and reappears, the modem is unstable.

### Solutions

| Problem | Fix |
|---------|-----|
| NAT timeout | Keepalives should handle this - check they're working |
| Aggressive carrier | VPN or different APN |
| Unstable modem | Check signal, try different USB port, update firmware |

---

## High Packet Loss

### Symptoms
- `--verbose` shows links with low window values
- Stream quality degrades
- Logs show many NAKs

### Diagnosis

**1. Check per-link status:**
```bash
srtla_send ... --verbose 2>&1 | grep -i "window"
```

Look for links with significantly lower window values than others: those are the ones
the sender is already deprioritizing. On the receiver, `--metrics_port` with
`--metrics_detail` exposes the same picture per connection (`srtla_conn_window`,
`srtla_conn_in_flight`, `srtla_conn_packets_lost_total`, `srtla_conn_weight_percent`).

**2. Check signal strength (for cellular):**
```bash
# If using ModemManager
mmcli -m 0 --signal-get
```

**3. Check MTU issues:**
```bash
# Test path MTU
ping -M do -s 1472 <receiver_ip>

# If "Frag needed" errors, MTU is too high
```

### Solutions

| Problem | Fix |
|---------|-----|
| Poor signal | Reposition modem, use external antenna |
| MTU too high | Reduce SRT encoder MTU to 1400 |
| Network congestion | Switch to less congested carrier/band |
| Bad modem | Try different modem/SIM |

---

## Stream Stuttering

### Symptoms
- Video plays but stutters/freezes periodically
- Audio cuts in and out

### Causes

**1. UDP buffer overflow**

Check current limits:
```bash
sysctl net.core.rmem_max
sysctl net.core.wmem_max
```

If less than 33554432 (32MB):
```bash
sudo sysctl -w net.core.rmem_max=67108864
sudo sysctl -w net.core.wmem_max=67108864
```

**2. SRT latency too low**

If your round-trip time to the receiver is high, SRT needs more latency headroom to recover from packet loss. Check RTT first:
```bash
ping <receiver_ip>
```

Set SRT latency to a comfortable multiple of your measured RTT. Too little headroom and SRT can't retransmit in time; too much adds unnecessary delay.

**3. CPU overload**

On sender:
```bash
top -p $(pidof srtla_send)
```

On receiver:
```bash
top -p $(pidof srtla_rec)
```

If CPU is saturated, consider reducing encoder bitrate or moving to more capable hardware.

---

## Link Quality Looks Wrong

### Symptoms
- A link shows poor quality despite good signal
- One link is consistently deprioritized even though the modem looks healthy
- Quality weight drops unexpectedly and doesn't recover

### Background

The receiver tracks per-connection quality using both receiver-side measurements and sender telemetry from extended keepalive packets. Each connection accumulates error points based on bandwidth, packet loss, RTT, NAK rate, and window utilization, which map to a weight level. See [HOW_IT_WORKS.md](HOW_IT_WORKS.md) for the full quality model.

### Diagnosis

**1. Check source routing first:**

A link that routes through the wrong physical interface will look degraded because its traffic competes with another link on the same path. This is the most common cause of unexpected quality issues.

```bash
ip rule show
ip route get 8.8.8.8 from <link_ip>
```

See [NETWORK_SETUP.md](NETWORK_SETUP.md) for how to fix source routing.

**2. Check for recovery mode:**

A connection in recovery mode receives more frequent keepalives while the receiver waits to see if it stabilizes. Run with `--verbose` and look for recovery-related log messages.

**3. Check the comparison logs:**

With `srtla_rec --verbose`, every weight change logs a `[COMPARISON]` line showing the
weight and error points from the connection-info path next to the legacy receiver-only
path. Large divergences point to RTT or NAK issues that only the sender's telemetry
reveals (or, the other way round, to a sender that is not sending extended keepalives
at all; check the `srtla_conn_extended_keepalives` gauge or the `Evaluation mode:`
debug line).

**4. Check for NAT interference:**

Some carriers reset UDP flows mid-stream. If a connection drops and re-registers frequently, the quality evaluator will penalize it. A VPN or different APN may help.

### Solutions

| Problem | Fix |
|---------|-----|
| Wrong source routing | Fix policy rules (see [NETWORK_SETUP.md](NETWORK_SETUP.md)) |
| High RTT on one link | Reposition modem, check signal, try different band |
| Frequent re-registration | Carrier NAT interference — try VPN or different APN |
| Link stuck in recovery | Check modem stability with `watch ip addr show <iface>` |

---

## Debugging Tools

### Verbose Logging

Both sender and receiver support `--verbose`:

```bash
srtla_send 5000 relay.example.com 5001 /tmp/srtla_ips --verbose
srtla_rec --srtla_port 5000 --srt_hostname 127.0.0.1 --srt_port 5001 --verbose
```

### Packet Capture

On receiver, capture SRTLA traffic:
```bash
sudo tcpdump -i any port 5000 -w srtla.pcap
```

Analyze with Wireshark - look for:
- Packets from different source IPs (bonding working)
- REG1/REG2/REG3 exchanges (registration)
- Keepalive packets (NAT maintenance)

### Check Routing in Real-Time

```bash
# Watch policy rules
watch -n 1 "ip rule show"

# Watch specific interface
watch -n 1 "ip addr show usb0; ip route show table usb0"
```

### Syslog Messages

The DHCP hook and NM dispatcher log to syslog:
```bash
grep "SRTLA" /var/log/syslog
journalctl -f | grep -i srtla
```

### Test Individual Links

Force traffic through a specific interface:
```bash
# Ping through usb0 only
ping -I 10.0.0.10 <receiver_ip>

# TCP test through specific source
curl --interface 10.0.0.10 http://example.com
```

### Prometheus Metrics (receiver)

`srtla_rec --metrics_port 9997` serves the full counter set over HTTP; every path returns
the same body.

```bash
curl -s http://127.0.0.1:9997/metrics | grep -E 'srtla_(groups|connections|group_registrations)'
```

The first numbers worth reading during an incident:

| Metric | What it tells you |
|--------|-------------------|
| `srtla_group_registrations_rejected_total{reason}` | why senders are being turned away: `throttled`, `table_full`, `duplicate_address`, `send_error` |
| `srtla_conn_registrations_rejected_total{reason}` | per-link joins refused: `no_group`, `group_mismatch`, `max_conns`, `send_error` |
| `srtla_groups_removed_total{reason}` | `idle_timeout`, `auth_failed`, `srt_error`, `evicted` |
| `srtla_auth_failures_total`, `srtla_auth_sources_blocked` | the SRT-auth throttle is tripping |
| `srtla_packets_received_total` / `srtla_recv_batches_total` | receive-loop fill ratio; climbing means the loop is nearing saturation |
| `srtla_conn_*` (with `--metrics_detail`) | per-link RTT, window, in-flight, weight, loss, and whether the sender sends extended keepalives |

`docs/grafana-dashboard.json` has a panel for every metric. The endpoint binds
`127.0.0.1` by default; `--metrics_bind ::` opens it on every interface, so firewall it.

---

## Receiver Rejecting Registrations

### Symptoms
- The sender registers, streams briefly, then every re-registration attempt fails for
  about a minute
- `srtla_group_registrations_rejected_total{reason="throttled"}` and
  `srtla_auth_sources_blocked` climb
- Several broadcasters behind one NAT lose access together

### Cause

`srtla_rec` relays the SRT handshake but never authenticates it. When the downstream SRT
server rejects a handshake (wrong stream ID or passphrase), the receiver counts that
against the source IP. `AUTH_FAIL_THRESHOLD` (5) failures inside `AUTH_FAIL_WINDOW`
(60 s) block new registrations from that IP for `AUTH_FAIL_COOLDOWN` (60 s). A sender
that reconnects in a tight loop with bad credentials locks itself out, and everyone
sharing its public IP with it.

### Solutions

| Problem | Fix |
|---------|-----|
| Wrong stream ID / passphrase on the sender | Fix the encoder's SRT URL; the block clears itself after the cooldown |
| Many broadcasters behind one NAT | Give them distinct public IPs, or accept the shared blast radius |
| Downstream SRT server down | The rejects are its handshake failures; fix the server first |

The thresholds live in `src/receiver_config.h`. They are upstream's values and this repo
does not change them.

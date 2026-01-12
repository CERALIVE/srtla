# SRTLA Troubleshooting Guide

Common issues and how to diagnose them.

## Table of Contents

- [No Connections Established](#no-connections-established)
- [Only One Link Working](#only-one-link-working)
- [Connections Keep Dropping](#connections-keep-dropping)
- [High Packet Loss](#high-packet-loss)
- [Stream Stuttering](#stream-stuttering)
- [Debugging Tools](#debugging-tools)

---

## No Connections Established

### Symptoms
- `srtla_send` logs: "Failed to establish any initial connections"
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
# Run srtla_send with --verbose
srtla_send ... --verbose 2>&1 | grep keepalive
```

Should show periodic "sending keepalive" messages.

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
srtla_send ... --verbose 2>&1 | grep "window"
```

Look for links with window << 20000 (the default).

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

If your RTT (round-trip time) is high, SRT needs more latency:
```bash
# Check RTT to receiver
ping <receiver_ip>

# SRT latency should be at least 2-3× RTT
# If RTT is 200ms, use at least 500ms latency
```

**3. CPU overload**

On sender:
```bash
top -p $(pidof srtla_send)
```

On receiver:
```bash
top -p $(pidof srtla_rec)
```

If CPU is near 100%, consider:
- Reducing encoder bitrate
- Using hardware more powerful

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

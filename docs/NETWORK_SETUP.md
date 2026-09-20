# SRTLA Network Setup Guide

This guide explains how to configure the **sender host** (the Linux box with the modems)
for proper multi-network bonding with SRTLA. The receiver in this repo needs no special
routing; it listens on one UDP port. The sender is the Rust
[srtla-send-rs](https://github.com/CERALIVE/srtla-send-rs) `srtla_send`, which reads its
source IPs from a file and reloads that file on `SIGHUP`. Everything below applies to it.

For protocol internals and how the connection model works, see [HOW_IT_WORKS.md](HOW_IT_WORKS.md).

## Table of Contents

- [Why This Matters](#why-this-matters)
- [The Core Problem](#the-core-problem)
- [Managing the IP List](#managing-the-ip-list)
- [Step-by-Step Setup](#step-by-step-setup)
- [Verification](#verification)
- [Quick Reference](#quick-reference)

---

## Why This Matters

SRTLA bonds multiple network connections by sending packets through different source IP addresses. However, **Linux doesn't automatically route packets through the correct interface just because you bound to a specific IP**.

Without proper configuration:
- All your packets go through ONE interface (usually the first one that connected)
- Your other modems sit idle
- You get zero benefit from bonding

The receiver tracks per-connection quality continuously. That tracking only produces useful signal when each connection genuinely uses its own link. Misconfigured routing silently undermines the whole system.

---

## The Core Problem

### Default Linux Routing Behavior

```
┌──────────────────────────────────────────────────────────────┐
│                                                              │
│   You have 3 modems:                                         │
│   • usb0: 10.0.0.10 (T-Mobile)                              │
│   • usb1: 10.0.1.10 (Verizon)                               │
│   • usb2: 10.0.2.10 (AT&T)                                  │
│                                                              │
│   SRTLA binds sockets to each IP and sends packets...       │
│                                                              │
│   BUT the kernel routing table says:                         │
│   "default via 10.0.0.1 dev usb0"                           │
│                                                              │
│   Result: ALL packets exit through usb0!                     │
│   Your Verizon and AT&T modems do nothing.                  │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### The Solution: Policy Routing

Policy routing adds rules that say: "If a packet comes FROM this IP, use THIS routing table."

```
┌──────────────────────────────────────────────────────────────┐
│                                                              │
│   Policy Rules:                                              │
│   • Packets from 10.0.0.10 → use routing table "usb0"       │
│   • Packets from 10.0.1.10 → use routing table "usb1"       │
│   • Packets from 10.0.2.10 → use routing table "usb2"       │
│                                                              │
│   Each table has its own default gateway:                    │
│   • Table usb0: default via 10.0.0.1 dev usb0               │
│   • Table usb1: default via 10.0.1.1 dev usb1               │
│   • Table usb2: default via 10.0.2.1 dev usb2               │
│                                                              │
│   Result: Each source IP routes through its own modem! ✓    │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## Managing the IP List

`srtla_send` takes the source-IP file as its fourth positional argument
(`srtla_send <SRT_LISTEN_PORT> <SRTLA_HOST> <SRTLA_PORT> <BIND_IPS_FILE>`); `/tmp/srtla_ips`
is the conventional path used below. One IP per line. Something needs to:

1. **Detect** which network interfaces are available
2. **Write** their IPs to the file
3. **Signal** `srtla_send` to reload when interfaces change

### Option 1: CeraUI (Automatic)

If you're using CeraUI, this is handled automatically. CeraUI:

- Scans network interfaces on startup
- Writes enabled interface IPs to `/tmp/srtla_ips`
- Listens for network changes (modem connect/disconnect)
- Sends `SIGHUP` to `srtla_send` when the list changes

```
┌─────────────────────────────────────────────────────────────┐
│                     CeraUI Backend                          │
│                                                             │
│  Modem connects ──▶ Detect new IP ──▶ Update file ──▶ SIGHUP│
│                                                             │
│  Modem disconnects ──▶ Detect removal ──▶ Update ──▶ SIGHUP │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

CeraUI owns the file and the signal; nothing else on the device should write it. A
reload that resolves to zero valid IPs (missing file, empty file, all-garbage lines) is
refused by the sender and the current links keep running, so a transient bad write does
not drop the stream.

### Option 2: Shell Script (Manual/Standalone)

For standalone use without CeraUI, create a script that monitors interfaces:

```bash
#!/bin/bash
# /usr/local/bin/srtla-ip-monitor.sh
# Monitors network interfaces and updates srtla_ips file

IPS_FILE="/tmp/srtla_ips"
LAST_HASH=""

update_ips() {
    # Get all non-loopback IPv4 addresses
    NEW_IPS=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.')
    NEW_HASH=$(echo "$NEW_IPS" | md5sum)
    
    # Only update if changed
    if [ "$NEW_HASH" != "$LAST_HASH" ]; then
        echo "$NEW_IPS" > "$IPS_FILE"
        LAST_HASH="$NEW_HASH"
        
        # Signal srtla_send to reload
        pkill -HUP srtla_send 2>/dev/null
        
        logger "SRTLA IPs updated: $(echo $NEW_IPS | tr '\n' ' ')"
    fi
}

# Initial update
update_ips

# Monitor for changes (using ip monitor)
ip monitor address | while read -r line; do
    update_ips
done
```

Run as a service:

```bash
# /etc/systemd/system/srtla-ip-monitor.service
[Unit]
Description=SRTLA IP Monitor
After=network.target

[Service]
ExecStart=/usr/local/bin/srtla-ip-monitor.sh
Restart=always

[Install]
WantedBy=multi-user.target
```

### Option 3: DHCP Hook (Integrated with Routing)

You can extend the DHCP hook to also update the IP list:

```bash
# Add to /etc/dhcp/dhclient-exit-hooks.d/srtla-source-routing

# After setting up routing, also update the IP list
update_srtla_ips() {
    ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' > /tmp/srtla_ips
    pkill -HUP srtla_send 2>/dev/null
}

case "$reason" in
    BOUND|RENEW|REBIND|REBOOT|EXPIRE|FAIL|RELEASE|STOP)
        update_srtla_ips
        ;;
esac
```

---

## Step-by-Step Setup

### Step 1: Create Routing Tables

Linux needs named routing tables. Add these to `/etc/iproute2/rt_tables`:

```bash
# USB modems (usb0 - usb4)
printf "100 usb0\n101 usb1\n102 usb2\n103 usb3\n104 usb4\n" | sudo tee -a /etc/iproute2/rt_tables

# Ethernet interfaces (eth0 - eth4)  
printf "110 eth0\n111 eth1\n112 eth2\n113 eth3\n114 eth4\n" | sudo tee -a /etc/iproute2/rt_tables

# WiFi interfaces (wlan0 - wlan4)
printf "120 wlan0\n121 wlan1\n122 wlan2\n123 wlan3\n124 wlan4\n" | sudo tee -a /etc/iproute2/rt_tables
```

### Step 2: Automatic Routing for USB/Ethernet Modems

Modems get new IPs via DHCP. We need routes to update automatically.

Create `/etc/dhcp/dhclient-exit-hooks.d/srtla-source-routing`:

```bash
#!/bin/bash
# Automatic source-based routing for SRTLA
# Triggers on DHCP events for interfaces in /etc/network/interfaces

if [ -n "$new_ip_address" ] && [ -n "$new_routers" ]; then
    # Map interface name to routing table
    case "$interface" in
        usb[0-4]) table_id=$((100 + ${interface#usb})) ;;
        eth[0-4]) table_id=$((110 + ${interface#eth})) ;;
        *)        exit 0 ;;  # Ignore other interfaces
    esac
    
    table_name="$interface"
    
    case "$reason" in
        BOUND|RENEW|REBIND|REBOOT)
            # Clear old routes
            ip route flush table $table_name 2>/dev/null
            
            # Add default route for this interface's table
            ip route add default via $new_routers dev $interface table $table_name
            
            # Add policy rule: packets FROM this IP use this table
            ip rule del from $new_ip_address 2>/dev/null
            ip rule add from $new_ip_address table $table_name priority $table_id
            
            logger "SRTLA: $interface ($new_ip_address) → table $table_name via $new_routers"
            ;;
            
        EXPIRE|FAIL|RELEASE|STOP)
            ip route flush table $table_name 2>/dev/null
            ip rule del from $new_ip_address 2>/dev/null
            logger "SRTLA: removed $interface ($new_ip_address)"
            ;;
    esac
fi
```

Make executable:
```bash
sudo chmod +x /etc/dhcp/dhclient-exit-hooks.d/srtla-source-routing
```

### Step 3: Automatic Routing for WiFi

WiFi is managed by NetworkManager. Create `/etc/NetworkManager/dispatcher.d/srtla-wifi-routing`:

```bash
#!/bin/bash
# Source routing for WiFi interfaces

IFACE="$1"
ACTION="$2"

case "$IFACE" in
    wlan[0-4]) ;;
    *) exit 0 ;;
esac

table_id=$((120 + ${IFACE#wlan}))
table_name="$IFACE"

case "$ACTION" in
    up)
        IP=$(ip -4 addr show dev $IFACE | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
        GW=$(ip route show dev $IFACE | grep -oP '(?<=default via )\d+(\.\d+){3}' | head -1)
        
        if [ -n "$IP" ] && [ -n "$GW" ]; then
            ip route flush table $table_name 2>/dev/null
            ip route add default via $GW dev $IFACE table $table_name
            ip rule del from $IP 2>/dev/null
            ip rule add from $IP table $table_name priority $table_id
            logger "SRTLA WiFi: $IFACE ($IP) → table $table_name via $GW"
        fi
        ;;
    down)
        ip route flush table $table_name 2>/dev/null
        logger "SRTLA WiFi: removed $IFACE"
        ;;
esac
```

Make executable:
```bash
sudo chmod +x /etc/NetworkManager/dispatcher.d/srtla-wifi-routing
```

### Step 4: Configure Modem Interfaces

For reliable multi-modem setup (especially when modems share MAC addresses), use `/etc/network/interfaces`:

```
# /etc/network/interfaces
auto lo
iface lo inet loopback

# USB modems
auto usb0
iface usb0 inet dhcp

auto usb1
iface usb1 inet dhcp

auto usb2  
iface usb2 inet dhcp

auto usb3
iface usb3 inet dhcp
```

> **Note**: Using `/etc/network/interfaces` instead of NetworkManager is more reliable for USB modems, especially Huawei models that share MAC addresses.

### Step 5: DNS Configuration

Mobile carriers provide DNS that only works through their network. Use public DNS:

```bash
# Add to /etc/resolvconf/resolv.conf.d/head
printf "\nnameserver 8.8.8.8\nnameserver 8.8.4.4\nnameserver 1.1.1.1\n" | sudo tee -a /etc/resolvconf/resolv.conf.d/head

# Apply changes
sudo resolvconf -u
```

### Step 6: UDP Buffer Sizes

SRTLA allocates large socket buffers to handle bursts without dropping packets. Ensure the system allows this:

```bash
# Add to /etc/sysctl.conf for persistence
echo "net.core.rmem_max=67108864" | sudo tee -a /etc/sysctl.conf
echo "net.core.wmem_max=67108864" | sudo tee -a /etc/sysctl.conf

# Apply now
sudo sysctl -p
```

---

## Verification

### Check Routing Tables Exist

```bash
cat /etc/iproute2/rt_tables | grep -E "(usb|eth|wlan)"
```

Expected output:
```
100 usb0
101 usb1
...
120 wlan0
...
```

### Check Policy Rules

```bash
ip rule show
```

Expected output (example with 2 modems):
```
0:      from all lookup local
100:    from 10.0.0.10 lookup usb0
101:    from 10.0.1.10 lookup usb1
32766:  from all lookup main
32767:  from all lookup default
```

### Test Source Routing

```bash
# Check which interface each source IP uses
ip route get 8.8.8.8 from 10.0.0.10
ip route get 8.8.8.8 from 10.0.1.10
```

Expected output:
```
8.8.8.8 from 10.0.0.10 via 10.0.0.1 dev usb0 table usb0
8.8.8.8 from 10.0.1.10 via 10.0.1.1 dev usb1 table usb1
```

### Verify with tcpdump (on receiver)

On sender:
```bash
ping -I 10.0.0.10 <receiver_ip>
ping -I 10.0.1.10 <receiver_ip>
```

On receiver:
```bash
tcpdump -i any icmp
```

You should see pings arriving from different source IPs.

---

## Quick Reference

| What | Why | File/Command |
|------|-----|--------------|
| Routing tables | Named tables for each interface | `/etc/iproute2/rt_tables` |
| DHCP hook | Auto-routing for USB/Ethernet | `/etc/dhcp/dhclient-exit-hooks.d/` |
| NM dispatcher | Auto-routing for WiFi | `/etc/NetworkManager/dispatcher.d/` |
| Interface config | Reliable modem enumeration | `/etc/network/interfaces` |
| DNS | Avoid carrier-specific DNS | `/etc/resolvconf/resolv.conf.d/head` |
| UDP buffers | Handle high-bitrate bursts | `/etc/sysctl.conf` |

---

## Common Issues

### "All packets go through one interface"

Check `ip rule show` — you should see rules for each IP. If not, the DHCP hook isn't running:
- Verify the hook is executable
- Check `/var/log/syslog` for "SRTLA" messages
- Try manually running `sudo dhclient usb0`

### "Modem gets IP but no routing rule"

The interface might be managed by NetworkManager instead of dhclient:
- Move it to `/etc/network/interfaces`
- Or create a NetworkManager dispatcher script

### "Routing works but SRTLA still uses one interface"

Check that `/tmp/srtla_ips` contains all your interface IPs:
```bash
cat /tmp/srtla_ips
```

Send SIGHUP to reload:
```bash
kill -HUP $(pidof srtla_send)
```

### "One link shows poor quality even with good signal"

The receiver's quality evaluator tracks per-connection health continuously. A link that routes through the wrong interface will show degraded quality because its traffic competes with another link's traffic on the same physical path. Verify source routing is correct before assuming the modem or carrier is at fault. See [HOW_IT_WORKS.md](HOW_IT_WORKS.md) for how quality evaluation works.

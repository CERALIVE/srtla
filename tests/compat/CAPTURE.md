# Capturing a Moblin SRTLA fixture for pcap replay

`pcap-replay/replay.sh` replays a captured `srtla_send`→`srtla_rec` session
against a fresh local `srtla_rec` and asserts registration, ≥500 forwarded
packets, and receiver liveness. It is **handshake-aware** (see
`pcap-replay/replay.py`): a blind packet replay cannot complete SRTLA
registration because the group id is `sender_half ‖ receiver_random` and the
receiver matches all 256 bytes, so the replayer learns the live receiver's REG2
nonce and rewrites it into the captured REG2 frames. This means **any clean
sender-side capture works** — you do not need to preserve receiver state.

The canonical fixture is a real **Moblin** sender session, committed to git-LFS
as `fixtures/real-moblin.pcap`. This document is the exact procedure to produce
it. When the fixture is absent the replay SKIPs (exit 77), so capturing it is
optional but recommended — it pins real third-party sender behaviour.

## Prerequisites

- A device or laptop running **Moblin** with SRTLA bonded output configured.
- A reachable host running our `srtla_rec` (the capture box; can be the same
  machine over loopback for a controlled capture).
- `tcpdump` (root / `CAP_NET_RAW`).
- The SRTLA receiver port Moblin targets — assume **5000** below.

## 1. Start the receiver pipeline

On the capture host, run a receiver and any downstream SRT sink (the sink only
needs to exist so the SRT handshake can flow; for the capture itself the bytes
are what matter):

```bash
# downstream SRT endpoint (any real SRT listener, e.g. the compat srt-sink)
srt-sink --port 4001 --host 127.0.0.1 --result /tmp/sink.json --duration 120 &

# our receiver
srtla_rec --srtla_port 5000 --srt_hostname 127.0.0.1 --srt_port 4001 \
          --log_level trace
```

## 2. Start the capture

Capture **both directions** of the SRTLA UDP flow. The replayer keeps only the
sender→receiver datagrams (those whose destination is the receiver port) and
auto-detects that port from the REG1 frame, so the receiver→sender direction is
harmless to include.

```bash
# loopback capture (Moblin and receiver on the same host):
sudo tcpdump -i lo   -w real-moblin.pcap 'udp port 5000'

# real network capture (Moblin on a separate device, <IFACE> faces the device):
sudo tcpdump -i <IFACE> -w real-moblin.pcap 'udp port 5000'
```

> Use a real interface only when Moblin runs on separate hardware. The link
> layer (Ethernet / Linux-cooked / loopback) is auto-detected by the parser.

## 3. Stream from Moblin

Point Moblin's SRTLA output at the receiver host:port and start streaming.

- **Duration:** ~60 s (well past the ≥500-packet threshold; gives a few
  keepalive cycles and at least one quality-evaluation pass at the receiver).
- **Content:** Moblin's normal H.264/AAC MPEG-TS over SRT. The exact scene is
  irrelevant — only packet structure and timing are replayed.
- **Links:** use the real bonded set (e.g. two cellular + WiFi) so the capture
  exercises multi-connection registration. The replayer collapses every source
  link onto one socket, which still registers the group plus one connection.

Stop `tcpdump` (Ctrl-C) once the stream has run ~60 s.

## 4. Anonymise and verify

A capture taken over loopback (`127.0.0.0/8`) carries no routable addresses and
needs no scrubbing. **A capture taken over a real network contains public/source
IPs and MUST be checked before committing.**

```bash
# 1. List every distinct IP pair in the capture.
tshark -r real-moblin.pcap -T fields -e ip.src -e ip.dst | sort -u

# 2. There must be NO real user/public addresses. If any appear, rewrite them
#    to documentation ranges (RFC 5737 / RFC 3849) before committing:
tcprewrite --infile=real-moblin.pcap --outfile=real-moblin.anon.pcap \
           --pnat=<public_subnet>:198.51.100.0/24
mv real-moblin.anon.pcap real-moblin.pcap

# 3. Confirm SRTLA registration is present (REG1 = 0x9200 on the receiver port).
python3 pcap-replay/replay.py replay real-moblin.pcap --port 5000 --speed 0 \
  2>&1 | head        # dry sanity check against a running srtla_rec, or:
tshark -r real-moblin.pcap -Y 'udp.payload[0:2] == 92:00'   # >=1 REG1 frame

# 4. Confirm payloads carry no plaintext PII (stream titles, keys, etc.).
strings real-moblin.pcap | grep -iE 'rtmp|stream|key|token|@' || echo clean
```

Do **not** commit a real-traffic capture until steps 1–4 are clean.

## 5. Expected file size

A ~60 s bonded stream at typical IRL bitrates (3–6 Mbps) is roughly
**25–50 MB**. The mock self-test fixture (~15 s, 2 Mbps loopback) is ~4.5 MB.
Anything under ~1 MB almost certainly missed the media phase — re-capture.

## 6. Commit the fixture (git-LFS)

`*.pcap` under `fixtures/` is tracked by git-LFS (`.gitattributes`). With LFS
installed (`git lfs install`):

```bash
cp real-moblin.pcap tests/compat/fixtures/real-moblin.pcap
git add tests/compat/fixtures/real-moblin.pcap
git lfs ls-files          # must list real-moblin.pcap
git commit -m "test(compat): add real Moblin SRTLA replay fixture"
```

Then run the replay against it:

```bash
tests/compat/pcap-replay/replay.sh           # default fixture path
```

Expected: `PASS` (registration completed, ≥500 packets delivered, receiver
alive). Without the fixture pulled, the same command SKIPs with exit 77.

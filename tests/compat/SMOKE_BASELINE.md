# BELABOX ↔ CeraLive `srtla_rec` Interop Smoke Baseline

**Date:** 2026-06-10 · **Verdict:** ✅ PASS

A live, end-to-end smoke test of the **stock BELABOX `srtla_send`** talking to **our
`srtla_rec`** over two bonded loopback links. The goal was to confirm — against
running binaries, not just code reading — that the **legacy interop path exists
today**: a sender with no extended-keepalive support streams cleanly, and the
receiver's `sender_supports_extended_keepalives` capability flag stays `false`
for the whole session (i.e. quality evaluation falls back to receiver-only
metrics, per `src/receiver_config.h`).

This is a manual baseline (not part of `ctest`). The dockerised, pinned-SHA
harness under `tests/compat/docker/` is the reproducible counterpart; this
document records a from-source native run for directness.

---

## Subjects under test

| Side | Source | Commit | Binary |
|------|--------|--------|--------|
| Receiver | this repo (`main`) | `20eba37` (source identical since `3f386b8`) | `build/srtla_rec` |
| Sender | `github.com/BELABOX/srtla` | `37862da` | `srtla_send` (plain `make`) |

Host: Arch Linux, kernel 7.0.x · libsrt **1.5.5** (`srt-live-transmit`) ·
ffmpeg n8.1.1 · tcpdump 4.99.6 · tshark 4.7.0.

---

## Topology

```
ffmpeg (SRT caller)
   │  srt://127.0.0.1:6000
   ▼
srtla_send 6000 127.0.0.1 5000 <ips>
   │  bond over 127.0.0.1 + 127.0.0.2
   ▼
srtla_rec --srtla_port 5000 --srt_hostname 127.0.0.1 --srt_port 4001
   │
   ▼
srt-live-transmit (SRT listener :4001) ──► file sink
```

Two source IPs (`127.0.0.1`, `127.0.0.2`) are bonded; `127.0.0.2/8` is added as a
loopback alias for the test.

---

## Build commands (verbatim)

**Our receiver** (from the repo root):

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Release .
cmake --build build -j"$(nproc)"      # → build/srtla_rec   (exit 0)
```

**Stock BELABOX sender:**

```bash
git clone https://github.com/BELABOX/srtla belabox-srtla --depth=1
make -C belabox-srtla                 # → belabox-srtla/srtla_send  (exit 0)
# needs only a C toolchain + system libsrt headers (libsrt-dev on Debian/Ubuntu)
```

---

## Run commands (verbatim)

```bash
# loopback alias for the second bonded link
sudo ip addr add 127.0.0.2/8 dev lo

# wire capture (out-of-tree, not committed)
sudo tcpdump -i lo -w smoke.pcap "udp port 5000"

# downstream SRT sink (listener → file). NB: this libsrt build only accepts
# file://con as a file target, so stdout is redirected to the sink file.
srt-live-transmit -q "srt://:4001?mode=listener&latency=200" file://con > srt-sink.ts

# our receiver, trace level so the legacy-keepalive fallback line is captured
build/srtla_rec --srtla_port 5000 --srt_hostname 127.0.0.1 --srt_port 4001 --log_level trace

# stock BELABOX sender, two bonded source IPs
printf '127.0.0.1\n127.0.0.2\n' > srtla_ips
belabox-srtla/srtla_send 6000 127.0.0.1 5000 srtla_ips

# SRT source: synthetic 480p/2 Mbps H.264 + AAC, ~40 s
ffmpeg -re -f lavfi -i testsrc2=size=854x480:rate=30 \
       -f lavfi -i sine=frequency=440 \
       -c:v libx264 -preset ultrafast -tune zerolatency -b:v 2000k -c:a aac \
       -f mpegts "srt://127.0.0.1:6000?mode=caller&latency=200&transtype=live"
```

---

## Observed handshake timing (receiver trace timestamps)

| Δ from receiver start | Event |
|------|-------|
| `T0` (`08:08:15.114`) | `srtla_rec is now running`; downstream SRT `127.0.0.1:4001` reachable (`Success`) |
| `+1.003 s` | `srtla_send` launched; **SRTLA REG completes in the same millisecond** (`08:08:16.117`) — `Group registered` + two `Connection registration` |
| `+3.046 s` | ffmpeg launched; first SRT media reaches the downstream socket `+42 ms` later (`Created SRT socket. Local Port: 46518`) |

Two `Connection registration failed: No group found` lines precede group creation.
This is the normal BELABOX startup race — the second link's registration arrives
before the group from the first link's `REG1` exists; the sender auto-retries and
both links register in the same millisecond.

---

## Result — Phase A (≥ 35 s stream)

| Assertion | Result |
|-----------|--------|
| `REG1 → REG2 → REG3` completes | ✅ `Group registered` + 2× `Connection registration` (receiver) |
| Streamed without crash/disconnect | ✅ full **40 s** window; 0 crash markers in receiver log |
| Bytes forwarded to downstream SRT | ✅ **11,485,108 bytes** (~11.5 MB; ≥ 1000 required) |
| Extended-KA path **not** activated | ✅ see below |

### Legacy-path proof

**Receiver log** (trace) over the whole session:

| Pattern | Hits |
|---------|------|
| `0xC01F` | **0** |
| `extended` | **0** |
| `Per-connection keepalive` (extended-KA parse) | **0** |
| `ALGO_CMP` (comparison emitted only on telemetry) | **0** |
| `without sender telemetry` (legacy fallback) | **4** |

Representative receiver excerpt:

```
[info]  [::ffff:52089] [Group: …] Group registered
[info]  [::ffff:52089] [Group: …] Connection registration
[info]  [::ffff:33854] [Group: …] Connection registration
[trace] [::ffff:52089] [Group: …] Keepalive without sender telemetry - quality evaluation will use receiver-only metrics
[trace] [::ffff:33854] [Group: …] Keepalive without sender telemetry - quality evaluation will use receiver-only metrics
[info]  [Group: …] Created SRT socket. Local Port: 46518
```

`update_connection_telemetry()` is never called, so
`sender_supports_extended_keepalives` stays **false** for every connection — the
documented receiver-only-metrics fallback is exactly what runs.

### Wire proof (tshark over the capture)

The captured `udp port 5000` stream (18,188 packets) contains only **standard**
SRTLA keepalives:

```
   4  9000                                                                 (2-byte bare keepalive — BELABOX sender)
   4  9000000000000000000000000000000000000000000000000000000000000000     (32-byte zero-padded echo — our pad_sendto)
```

- **Zero** 38-byte (`SRTLA_KEEPALIVE_EXT_LEN`) keepalives; **zero** `0xC01F`
  magic in any SRTLA control packet (`0x90xx` / `0x92xx`).
- Registration packets seen on the wire: `REG1` ×1, `REG2` ×16, `REG3` ×2.
- The `c01f` byte sequence does appear 624× elsewhere — entirely inside SRT
  **media data** packets (`0x4xxx` / `0x8xxx`), i.e. incidental H.264/TS bytes,
  never at a keepalive magic offset.

---

## Phase B — receiver restart scenario (baseline capture, **not asserted**)

Procedure: kill `srtla_rec` mid-stream (sender + source left running), wait 15 s,
restart it, observe for 30 s.

Verbatim observations:

- **Source side:** killing the receiver broke the end-to-end SRT session, so
  ffmpeg (the SRT caller) terminated with `Conversion failed!`. There was no
  live media source during the reconnect window.
- **Sender side:** BELABOX `srtla_send` stayed up but emitted **no new log lines**
  throughout the 15 s outage and the 30 s post-restart window (last line:
  `Added connection via 127.0.0.2 (…)`).
- **Restarted receiver** (fresh, empty group table) logged only:

  ```
  [info]  Trying to connect to SRT at 127.0.0.1:4001...
  [info]  Success
  [info]  srtla_rec is now running
  [error] [::ffff:52089] Connection registration failed: No group found
  [error] [::ffff:33854] Connection registration failed: No group found
  ```

- **Sink:** 0 new bytes within the 30 s window (delta = 0).

**Interpretation (descriptive only):** a freshly-restarted receiver has no record
of the sender's prior group ID, so the sender's in-flight connections are
rejected with `No group found`. BELABOX recovers only by initiating a new `REG1`
(new group) after its own connection timeout, which did not occur inside the
30 s observation window; and because the SRT source had already exited, no media
would flow even on SRTLA re-registration. Recorded as a baseline, not a pass/fail
criterion.

---

## Verdict

✅ **PASS.** Stock BELABOX `srtla_send` interoperates with our `srtla_rec` over the
legacy (non-extended-keepalive) path **today**: full SRTLA registration, ~11.5 MB
of bonded media forwarded over 40 s across two links, no crash, and the
`sender_supports_extended_keepalives` fallback flag stays `false` for the entire
session.

# moblin-mock — Moblin SRTLA conformance mock sender

A source-faithful re-implementation of the SRTLA **client** (sender) wire
behaviour of [Moblin](https://github.com/eerimoq/moblin), used as a `blocking`
sender in the compat matrix (`tests/compat/matrix.yaml`). It lets us verify that
our `srtla_rec` interoperates with Moblin's exact handshake, keepalive,
reconnect and network-path-change semantics **without compiling Swift or running
the Moblin app**.

- **Pinned to** Moblin `0ae5294950166978064840bc874bfed3a8cf03a4` (the
  `moblin-mock` pin in `matrix.yaml`).
- **Every wire behaviour is source-cited** in [`BEHAVIOR.md`](BEHAVIOR.md)
  (`[B1]`..`[B7]`). `moblin_mock.py` annotates each behaviour with its `[Bn]`
  tag; the two must stay in sync.

## Files

| File | Purpose |
|------|---------|
| [`BEHAVIOR.md`](BEHAVIOR.md) | Source of truth: ≥6 documented Moblin behaviours with permalinks |
| `moblin_mock.py` | The mock sender (Python; SRTLA layer + SRT relay) |
| `Dockerfile` / `entrypoint.sh` | Builds `compat/moblin-mock`; feeds a looping MPEG-TS test pattern as the SRT caller |
| `ip-change-test.sh` | Mid-stream source-IP-change scenario with explicit assertions |

## What the mock does

It plays the same role as `srtla_send` — the SRTLA layer between a local SRT
caller (ffmpeg) and the SRTLA receiver — but speaks Moblin's protocol:

```
ffmpeg (SRT) --UDP--> [local listener] moblin_mock [uplink] --UDP--> srtla_rec --SRT--> srt-sink
```

Handshake (Moblin's quirk — a REG2 *probe* precedes REG1):

```
REG2(random) → REG_NGP → REG1(random) → REG2(full id) → REG2(full id) → REG3 → stream
```

Keepalives are the faithful **10-byte timestamped** form (never the 38-byte
extended variant), sent every second. See `BEHAVIOR.md` for the full list.

## Build & run the pair

```bash
# build the compat helpers (srt-sink) and our binaries once
cmake -B build -DBUILD_COMPAT_TESTS=ON && cmake --build build -j

# build the mock image
docker build --platform linux/amd64 -t compat/moblin-mock tests/compat/moblin-mock

# run the blocking pair against our receiver
SRTLA_BUILD_DIR=build tests/compat/run-matrix.sh --pair moblin-mockxours --duration 20
```

Pass criteria are the harness defaults: handshake ≤ 5 s, `bytes_received ≥ 1000`,
`disconnects == 0`, clean teardown.

## IP-change scenario

`ip-change-test.sh` runs the mock natively with `--ip-change-at-sec`, rebinds the
uplink source IP mid-stream (`127.0.0.1` → `127.0.0.2`), and asserts the
**documented** receiver reaction: the existing group continues and the new source
re-registers into it via REG2/REG3 (no new REG1, no second group, no disconnect).

```bash
SRTLA_BUILD_DIR=build tests/compat/moblin-mock/ip-change-test.sh
```

It exits non-zero if the expectation is violated (e.g. the receiver creates a
second group, or the stream drops), so it is a real, falsifiable test.

## Standalone mock usage

```bash
python3 moblin_mock.py --receiver-host 127.0.0.1 --receiver-port 5000 \
    --local-srt-port 6000 --bind-ip 127.0.0.1 \
    [--ip-change-at-sec 4 --ip-change-to 127.0.0.2]
# then point an SRT caller at srt://127.0.0.1:6000?mode=caller
```

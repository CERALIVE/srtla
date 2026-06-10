# srtla — SRT Link Aggregation

Parent: [`../AGENTS.md`](../AGENTS.md)

## ROLE IN THE GROUP

Bonds multiple uplinks (LTE, WiFi) into a single SRT stream. Produces `srtla_send` (device-side) and `srtla_rec` (server-side) binaries plus TypeScript bindings.

Consumers:
- **CeraUI backend** — TS bindings via `link:../../../srtla/bindings/typescript` (`@ceralive/srtla`)
- **Device image** — `srtla` .deb (built by `image-building-pipeline`)
- **obs-srtla-sender-plugin** — runtime dep only, not in device image

## OVERVIEW

Fork of [BELABOX/srtla](https://github.com/BELABOX/srtla) with contributions from IRLToolkit, IRLServer, OpenIRL, and CeraLive. C/C++/CMake. Deps: spdlog, argparse.

Remotes:
- `origin` — https://github.com/CERALIVE/srtla (canonical)
- `irlserver` — https://github.com/irlserver/srtla (upstream)

## UPSTREAM MERGE STATUS

The `irlserver/main` catch-up merge is **complete** (pinned at `aa66a88`, 63/63 ctest green). The `irlserver` remote is retained for future catch-ups. The TS bindings API is **settled** — safe to depend on; the additive telemetry module (`bindings/typescript/src/sender/`) was added post-merge but existing exports are frozen.

## STRUCTURE

```
srtla/
├── bindings/typescript/   # TS bindings for srtla_send / srtla_rec
│   ├── src/               # binding source
│   │   └── sender/        # sender args, process helpers, telemetry reader
│   ├── dist/              # compiled output (consumed by CeraUI backend)
│   └── package.json       # package: @ceralive/srtla
├── docs/                  # protocol + ops docs (see below)
│   └── adr/               # architecture decision records
├── src/                   # C/C++ source
│   └── sender_telemetry.h # ADR-001 telemetry serializer (header-only)
├── tests/                 # GTest suites + compat harness
│   ├── compat/            # cross-impl compatibility harness (see COMPAT HARNESS)
│   └── KNOWN_BUGS.md      # open defects + resolved entries with commit refs
└── CMakeLists.txt
```

## DOCS

Don't duplicate — read the source files:

| File | Content |
|------|---------|
| `docs/HOW_IT_WORKS.md` | Protocol internals, packet flow, connection groups, observability events |
| `docs/COMPATIBILITY.md` | Ecosystem research: which impls interop, which don't, and why |
| `docs/NETWORK_SETUP.md` | Multi-interface routing, NAT, firewall rules |
| `docs/TROUBLESHOOTING.md` | Common failure modes, diagnostics, structured lifecycle events |
| `docs/EXTENSION_POINTS.md` | GroupIdentity hooks and extension surface |
| `docs/keepalive-improvements.md` | NAT keepalive design notes |
| `docs/connection-info-comparison.md` | Per-connection quality tracking design |
| `docs/adr/ADR-001-telemetry-ipc.md` | Decision record: sender telemetry IPC transport (Option A — stats file) |

## BUILD

```bash
cmake -B build && cmake --build build
# Produces: build/srtla_send, build/srtla_rec

# TS bindings
cd bindings/typescript && bun install && bun run build
```

## COMPAT HARNESS

`tests/compat/` runs real end-to-end interop between our binaries and pinned
external SRTLA implementations. `matrix.yaml` is the pair registry; the harness
is `run-matrix.sh`:

```bash
cmake -B build -DBUILD_COMPAT_TESTS=ON && cmake --build build -j   # builds helpers
tests/compat/run-matrix.sh --pair oursxours --duration 20          # one pair
tests/compat/run-matrix.sh --tier blocking                         # whole tier
```

- `BUILD_COMPAT_TESTS=ON` is the **only** place srtla links the system libsrt —
  it builds `srt-sink` (mock SRT endpoint that counts bytes / writes result JSON)
  and `ext-ka-probe` (sends a real extended keepalive so the receiver's
  telemetry path can be verified; our `srtla_send` only emits the bare 2-byte
  keepalive). Default build is unaffected (option is OFF).
- "ours" = local build-dir binaries; external impls = `compat/*` Docker images
  from `tests/compat/docker/` (host network, amd64).
- Per-pair verdicts land in `tests/compat/results/<pair>/result.json` (gitignored).
- Pass criteria: handshake ≤10s (end-to-end first byte; `HANDSHAKE_MAX_MS`),
  `bytes_received ≥ 1000`, `disconnects == 0`, clean SIGTERM teardown. The harness
  is falsifiable — `--scenario port-mismatch` must fail.
- Both tiers (blocking and informational) gate PR CI; only the weekly upstream-drift
  job (unpinned HEADs) is non-blocking.

## COMPATIBILITY TESTING

The compat matrix (`tests/compat/matrix.yaml`) registers every tested sender/receiver
pair with its tier (`blocking` / `informational`) and expected verdict. Run the
blocking tier before any release:

```bash
tests/compat/run-matrix.sh --tier blocking
```

See `docs/COMPATIBILITY.md` for the full ecosystem research behind the matrix entries.

## TEST SUITES

GTest suites under `tests/` (all must stay green; run via `ctest` after a normal build):

| Suite file | What it pins |
|------------|-------------|
| `test_registration_handshake.cpp` | REG1/REG2/REG3 state machine, malformed-frame contracts |
| `test_extended_keepalive.cpp` | Extended-KA activation, fallback, and edge semantics |
| `test_reg_race.cpp` | REG3/NGP race, concurrent multi-interface registration |
| `test_group_limits.cpp` | MAX_GROUPS exhaustion, REG_ERR at cap |
| `test_timeout_cleanup.cpp` | Per-connection and group timeout/cleanup paths |
| `test_identity_hooks.cpp` | GroupIdentity extension hooks (see `docs/EXTENSION_POINTS.md`) |
| `test_telemetry_emit.cpp` | ADR-001 stats-file serialization, atomic publish, staleness |
| `test_sender_bootstrap.cpp` | Bootstrap registration, SIGHUP reload guard |

Compat scenarios under `tests/compat/scenarios/` (run by the harness):

| Scenario | Proves |
|----------|--------|
| `receiver-restart.sh` | Sender re-registers within ~5 s after receiver SIGKILL+restart |
| `link-drop.sh` | Sender shifts off an isolated link within CONN_TIMEOUT; survivor stays up |
| `sighup-reload.sh` | New IP joins group on SIGHUP with 0 disconnects; garbage file refused |

## TELEMETRY

`srtla_send` can publish per-uplink JSON snapshots via `--stats-file <path>` (opt-in).
The transport is an atomic `rename(2)` rewrite so readers never see a torn document.
Design rationale and the full JSON schema are in `docs/adr/ADR-001-telemetry-ipc.md`.

Key facts for consumers:
- **Path convention:** `/tmp/srtla-send-stats-<listen_port>.json` (mirrors the receiver's `/tmp/srtla-group-<PORT>` files)
- **Write cadence:** every 1000 ms
- **Staleness threshold:** 5000 ms (defined in `src/sender_telemetry.h` as `SENDER_TELEMETRY_STALE_MS`)
- **Zero links:** still writes `"connections": []` — "running but idle" is distinct from "absent"
- **Absent file:** the TS binding returns `null`, never throws; stock senders produce no file

The TS binding reader lives in `bindings/typescript/src/sender/` alongside the existing
spawn/args helpers. It is an **additive** export — existing exports (`srtlaSendOptionsSchema`,
`buildSrtlaSendArgs`, spawn helpers) are frozen and unchanged.

## ANTI-PATTERNS

- Don't modify the TS bindings API without checking `UPSTREAM MERGE STATUS` above — existing exports are frozen; new functionality must be additive
- Don't add `srtla` to `irl-srt-server` — it uses system libsrt directly, no srtla dep
- Don't confuse `srtla_send` (device) with `srtla_rec` (server/cloud)
- Don't extend the `node:child_process` debt in bindings — new code uses Bun-native APIs (`Bun.file`, `Bun.connect`)

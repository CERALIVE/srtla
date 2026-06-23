# srtla — SRT Link Aggregation

Parent: [`../AGENTS.md`](../AGENTS.md)

## ROLE IN THE GROUP

Bonds multiple uplinks (LTE, WiFi) into a single SRT stream. Builds `srtla_send` (C sender, **deprecated** — see below) and `srtla_rec` (server-side receiver) binaries plus TypeScript bindings.

Consumers:
- **CeraUI backend** — TS bindings via `link:../../../srtla/bindings/typescript` (`@ceralive/srtla`)
- **Device image** — `srtla` .deb (built by `image-building-pipeline`); **receiver-only** as of the cutover release — ships `srtla_rec` only
- **obs-srtla-sender-plugin** — retired 2026-06-11 (was a runtime dep only, never in the device image; repo retained on GitHub)

## C SENDER DEPRECATED — RECEIVER-ONLY .deb (ADR-003)

The device-side sender is now **[srtla-send-rs](https://github.com/CERALIVE/srtla-send-rs)** (the Rust fork, ADR-003; v1.0.0 released). The C `srtla_send` is **DEPRECATED and no longer shipped**: the `srtla` .deb is **receiver-only** (`srtla_rec` only). The sender binary `/usr/bin/srtla_send` now comes from the `srtla-send-rs` package.

What this means in-tree:
- **Source and tests stay.** `src/sender.cpp` / `src/sender.h` / `src/sender_logic.h` and every GTest suite (incl. `test_sender_bootstrap.cpp`) remain in the repo and **still build and run** — `srtla_send` is a normal build target, exercised by `ctest` (19 suites). Only the **install/package payload** drops it (`install(TARGETS srtla_rec ...)` in `CMakeLists.txt`; the `srtla-send.service` systemd unit is no longer in the `publish-release.yml` FPM payload).
- **Do NOT delete the C sender source or its tests** (Rule E). It is the protocol reference and keeps the compat harness' C-sender pairs runnable.
- **TS bindings are unchanged.** `bindings/typescript` still ships `srtla_send` *and* `srtla_rec` helpers (`@ceralive/srtla`); the sender helpers now target the `srtla-send-rs` binary, which is CLI- and telemetry-compatible (ADR-003 parity layer).
- Device-image packaging: `srtla` provides `srtla_rec`; `srtla-send-rs` provides `srtla_send`. The fork's `.deb` declares `Conflicts/Replaces: srtla (<< <cutover-version>)`; that bound must be set to this receiver-only srtla release's version so the two packages coexist (sender from the fork, receiver from `srtla`).

## OVERVIEW

Fork of [BELABOX/srtla](https://github.com/BELABOX/srtla) with contributions from IRLToolkit, IRLServer, OpenIRL, and CeraLive. C/C++/CMake. Deps: spdlog, argparse.

Remotes:
- `origin` — https://github.com/CERALIVE/srtla (canonical)
- `irlserver` — https://github.com/irlserver/srtla (upstream)

## UPSTREAM MERGE STATUS

The `irlserver/main` catch-up merge is **complete** (merge commit `edc04d6`, merge-base advanced `2de6dbb` → `39e324a`, 186/186 ctest green, compat blocking tier 9/9 PASS). `irlserver/main` is now a **true ancestor** of our HEAD — `git merge-base HEAD 39e324a` returns `39e324a`. See `docs/notes/upstream-currency-2026-06.md` for the full currency report.

The `irlserver` upstream remote is **transient**: it is added inside a merge worktree, used for the fetch + pin-verify + merge, then removed before any push or PR (`scripts/upstream-merge.sh`). The working clone keeps only `origin` (CERALIVE) at rest. Do not leave an `irlserver` remote attached after a merge.

The TS bindings API is **settled** — safe to depend on; the additive telemetry module (`bindings/typescript/src/sender/`) was added post-merge but existing exports are frozen.

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
| `docs/adr/ADR-002-srt-patch-necessity.md` | Decision record: srt-patch necessity verdict and omission path (SAFE verdict, Task 20 authorized) |

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
- The `ceralive-srtla-send-rs` pair (the Rust fork, ADR-003) is neither: it runs a
  **pre-built release binary** resolved via `SRTLA_SEND_RS_BIN` (or a `srtla_send_rs`
  on PATH). Fetch it from the fork's v1.0.0 release `.deb` (`/usr/bin/srtla_send`);
  unset → that pair SKIPs like a missing Docker image. It is a **blocking** pair.
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
| `test_group_limits.cpp` | MAX_GROUPS exhaustion, REG_ERR at cap (fillers are data-seen — see RECEIVER HARDENING) |
| `test_ghost_group_eviction.cpp` | Ghost-group reaping/eviction at PENDING_GROUP_TIMEOUT; data-seen groups protected |
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
| `jitter-stress.sh` | Two links under 3 escalating live netem jitter phases (no loss) keep streaming with 0 reaps, both links registered, disconnects==0 (needs netem/CAP_NET_ADMIN) |

The scenarios are **sender-agnostic**: their behavioral greps match both the C
`srtla_send` and the Rust fork (different log wording — e.g. C "Added connection
via IP" vs fork "added uplink … via IP"; C "connection failed" vs fork "timed out;
attempting full socket reconnection"). The Rust fork is silent unless `RUST_LOG` is
set, so the sender launch in each scenario prefixes `RUST_LOG="${RUST_LOG:-info}"`
(a no-op for the C sender, which logs unconditionally). Run a scenario against the
fork by pointing `--build-dir` at a dir whose `srtla_send` is the fork binary.

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

## RECEIVER HARDENING

`srtla_rec` is a pre-auth UDP relay: a REG1 creates a connection group before any
SRT handshake, and the actual stream auth happens downstream at the SRT server.
Two upstream commits (`irlserver/main` `7855012`, `39e324a`) close the resulting
pre-auth abuse surfaces. All knobs live in `src/receiver_config.h`.

**1. Ghost-group eviction (anti table-exhaustion DoS).** A group that registered
but never forwarded real SRT data is a "ghost". `ConnectionGroup::mark_data_seen()`
is set on the first forwarded SRT packet (`SRTLAHandler::process_single_packet`),
promoting the group to non-evictable.

- Empty groups are reaped at `PENDING_GROUP_TIMEOUT` (5 s) if they never saw data,
  vs `GROUP_TIMEOUT` (30 s) once promoted (`ConnectionRegistry::cleanup_inactive`).
- At `MAX_GROUPS` (200) a new REG1 evicts the oldest ghost before returning
  `REG_ERR` (`evict_oldest_pending_group()`), so a REG1 flood cannot lock out the
  real broadcaster. Eviction skips any group with live connections or `data_seen`.

**2. Per-IP auth-fail rate limiter.** `src/utils/auth_rate_limiter.{cpp,h}`
(linked into `receiver_core_obj`). A failed SRT auth — a libsrt handshake reject,
or (as srt-live-server does) an SRT `SHUTDOWN` before the group is `established`
(server ACK seen) — is counted per source IP; a failed-auth group is torn down
immediately to reclaim its slot. Keys are IP-only so port rotation does not evade.

- `AUTH_FAIL_THRESHOLD` = 5 failures within
- `AUTH_FAIL_WINDOW` = 60 s trips a block; new REG1s are refused for
- `AUTH_FAIL_COOLDOWN` = 60 s. Lenient by design so a mistyped passphrase or
  several broadcasters behind one NAT are not locked out.

Test-infra note: pre-existing receiver tests model **real** streaming groups, so
their group factories call `mark_data_seen()` (`test_group_limits`,
`test_timeout_cleanup`); the ghost/eviction behavior itself is pinned by
`test_ghost_group_eviction.cpp`.

## RECEIVER QUALITY TUNING (RTT / jitter)

The receiver's RTT/jitter scoring (`src/quality/quality_evaluator.cpp`,
constants in `src/receiver_config.h`) was retuned to remove three latency-path
defects pinned by `tests/test_quality_rtt.cpp` and one recovery-cadence defect
pinned by `tests/test_timeout_boundaries.cpp`. The load-balancer weight mapping
(`error_points → weight_percent`) is unchanged; only the error-point inputs and
the keepalive cadence changed.

| Constant / behavior | Old | New | Why |
|---------------------|-----|-----|-----|
| RTT base penalty ceiling | `> RTT_THRESHOLD_CRITICAL (500ms) → +20` (saturated) | `> CRITICAL → +20`, `> RTT_THRESHOLD_SEVERE (1000ms) → +30`, `> RTT_THRESHOLD_EXTREME (2000ms) → +40` | The old scale capped at +20, so any RTT over 500ms saturated at `WEIGHT_FAIR`; multi-second RTT could never reach `WEIGHT_POOR`/`WEIGHT_CRITICAL`. The SEVERE/EXTREME tiers make the worse weight tiers reachable from RTT alone. Steady 0/150/250/600ms still map FULL/EXCELLENT/DEGRADED/FAIR (unchanged); 2000ms now reaches POOR. |
| Jitter penalty | flat `+10` when `stddev > RTT_VARIANCE_THRESHOLD (50ms)` (absolute, binary) | `+5` when `stddev > RTT_JITTER_RATIO_HIGH (1.0) × mean`, `+10` when `stddev > RTT_JITTER_RATIO_SEVERE (1.5) × mean` (relative, proportional) | 50ms absolute stddev is normal cellular jitter on a healthy ~150ms link, yet the flat +10 dropped such links a full tier (EXCELLENT→FAIR) and oscillated tiers across statistically-identical jitter batches. Scoring jitter as a fraction of the mean RTT leaves normal jitter penalty-free and only charges links whose jitter rivals (>1.0×) or exceeds (>1.5×) their own latency. `RTT_VARIANCE_THRESHOLD` is retired. |
| Recovery / NAT keepalive cadence | fired only from `ConnectionRegistry::cleanup_inactive`'s reaping body, throttled to `CLEANUP_PERIOD (3s)` | fired from a decoupled pass on every `cleanup_inactive` call, paced to `KEEPALIVE_PERIOD (1s)` via a new per-connection `last_keepalive_sent` stamp | A 5s `RECOVERY_CHANCE_PERIOD` window only delivered ~2 of the intended ~5 probes because the keepalive rode the 3s reaping throttle. Decoupling restores the documented 1s recovery cadence; the per-connection stamp prevents keepalive spam when the main loop polls `cleanup_inactive` many times in the same second. The reaping throttle itself is unchanged. |

No protocol/wire change, no config knob added beyond the constants above, and
the `ENABLE_ALGO_COMPARISON` legacy path / `legacy_weight_percent` are untouched.

## ANTI-PATTERNS

- Don't modify the TS bindings API without checking `UPSTREAM MERGE STATUS` above — existing exports are frozen; new functionality must be additive
- Don't add `srtla` to `irl-srt-server` — it uses system libsrt directly, no srtla dep
- Don't confuse `srtla_send` (device) with `srtla_rec` (server/cloud)
- Don't extend the `node:child_process` debt in bindings — new code uses Bun-native APIs (`Bun.file`, `Bun.connect`)

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

### srt-sink extended metrics

`tests/compat/srt-sink/` is the mock SRT receiver used by the compat harness. Beyond the original 4 frozen keys (`bytes_received`, `disconnects`, `handshake_ms`, `error`), `srt-sink` now emits 9 additional keys in `result.json`:

| Key | Source | Description |
|-----|--------|-------------|
| `ts_packets` | `ts_continuity.h` | Total 188-byte TS packets received |
| `ts_sync_errors` | `ts_continuity.h` | Packets whose first byte is not `0x47` |
| `ts_cc_errors` | `ts_continuity.h` | Continuity-counter discontinuities (excl. null PID 0x1FFF and adaptation-field `discontinuity_indicator`) |
| `pkt_rcv_loss` | `srt_bstats` `pktRcvLossTotal` | SRT-level receive loss (cumulative, summed across reconnects) |
| `pkt_rcv_drop` | `srt_bstats` `pktRcvDropTotal` | SRT-level receive drop (too-late packets) |
| `pkt_retrans` | `srt_bstats` `pktRetransTotal` | SRT-level retransmissions |
| `nakreport_readback` | `srt_getsockflag` `SRTO_NAKREPORT` | NAK-report policy **negotiated** on the accepted socket (`-1` = unreadable) |
| `lossmaxttl_readback` | `srt_getsockflag` `SRTO_LOSSMAXTTL` | reorder-tolerance ceiling negotiated on the accepted socket (`-1` = unreadable) |
| `reorderfreeze_readback` | `srt_getsockflag` opt id `120` | decay-freeze flag negotiated on the accepted socket (`-1` = unreadable / stock libsrt) |

The TS parser lives in `srt-sink/ts_continuity.h` (header-only, dependency-free). It reassembles 188-byte packets across `srt_recv` boundaries, tracks per-PID continuity counters, and excludes null PID `0x1FFF` and adaptation-only packets from CC checks. Unit tests: `srt-sink/ts_continuity_test.cpp` (registered as ctest `ts-continuity` in `srt-sink/CMakeLists.txt`).

**`--retransmitalgo 0|1`** — new `srt-sink` flag. Sets `SRTO_RETRANSMITALGO` on the listener (pre-bind, inherited by accepted sockets). `0` = always retransmit on NAK; `1` = selective retransmit (default SRT behavior).

**`--packetfilter <str>`** — new `srt-sink` flag. Sets `SRTO_PACKETFILTER` on the listener (pre-bind, inherited by accepted sockets). The accepted socket's negotiated filter is written to `result.json` as `"packetfilter"` (non-empty = FEC negotiated; `""` = responder cleared the filter).

**`--reorderfreeze 0|1`** — new `srt-sink` flag. Sets `SRTO_REORDERFREEZE` via the raw numeric opt id `(SRT_SOCKOPT)120` so it compiles against any libsrt version. Reports `reorderfreeze=on|off|unsupported` in the startup banner.

**Sockopt read-back (`nakreport_readback` / `lossmaxttl_readback` / `reorderfreeze_readback`).** After `srt_accept`, `srt-sink` reads the three policy options back off the **accepted** socket via `srt_getsockflag` (`SRTO_NAKREPORT`, `SRTO_LOSSMAXTTL`, opt id `120`) and writes them to `result.json` — the **negotiated** values, not the requested ones the banner echoes. This is what lets a campaign measured via `srt-sink` flags prove it reproduces irl-srt-server's `kSrtProfileTable` (`SLSSrt.cpp`) L1/L2 tuples. The fidelity assertion `tests/compat/lib/srt-sink-proxy-fidelity.sh` runs the L1 `{freeze=1,nak=1,ttl=40}` and L2 `{freeze=1,nak=0,ttl=40}` flag sets, asserts the read-backs equal those tuples, and runs a falsifier (`--lossmaxttl 30` must FAIL the L2 ttl=40 check, proving the value is read back not echoed). Evidence: `test-results/srt-sink-proxy-fidelity.json` (gitignored).

### Profile validation A/B matrix

`tests/compat/scenarios/profile-validation-matrix.sh` is the A/B orchestrator for the four non-FEC receive profiles. It runs paired alternating reps (baseline patched libsrt vs freeze profile) under netem reorder stress and gates on six quality clauses:

1. `disconnects == 0` (both arms)
2. `ts_sync_errors == 0` (profile arm)
3. `ts_cc_errors <= baseline median`
4. `median goodput >= 99% baseline`
5. `p95 pkt_rcv_drop <= baseline`
6. `wire_amp <= 1.10× baseline median` (wire bytes / bytes_received)

Registered in `matrix.yaml` as scenario `profile-validation-matrix` (tier: blocking, privileged: true). Run manually via `tests/compat/run-matrix.sh --tier blocking`. Results: all four non-FEC profiles (Balanced/Low-Latency/Resilient/Classic) PASS all six clauses; wire amplification ratios 1.054–1.078× (well under 1.10×). Evidence: `test-results/srt-receive-profiles/task-6-srt-receive-profiles.json`.

The `reorder-stress.sh` scenario is parameterized (BITRATE_KBPS, RX_LATENCY_MS, NAKREPORT, LOSSMAXTTL, REORDERFREEZE, PROFILE_LABEL, NETEM_SEED) plus the gain-hunt adverse-config axes (STEADY_LOSS_PCT, BURST_LOSS_PCT, RTT_SPREAD_MS — see Gain-hunt scaffold below) and emits TS-continuity + SRT counters + `goodput_bps` + `wire_amp` into `result.json`. Default run (all axes unset) is byte-identical to the pre-matrix behavior (Rule E).

**Reverse-channel metric (`reverse_wire_bytes` / `reverse_wire_amp`).** `setup_topology` now installs a countable `prio` root qdisc on `$PEERIF` **inside** the receiver netns (the veth peer defaults to `noqueue`, so the receiver→sender egress had no Sent counter). After phase ii the scenario reads that qdisc's Sent bytes and emits `metrics.reverse_wire_bytes` plus `metrics.reverse_wire_amp` (`reverse_wire_bytes / bytes_received`). This makes the periodic-NAK reverse cost visible so a recipe cannot false-promote on forward `wire_amp` alone (B3/O1). Additive keys; existing callers unaffected (Rule E). **Empirical finding:** in this SRTLA topology the reverse channel is dominated by per-packet broadcast ACKs, so NAK-**off** (which retransmits more without precise NAKs) typically costs **more** reverse than NAK-**on** — the metric's value is visibility, not a fixed direction.

**Sender seam (`SRTLA_SEND_RS_BIN` / `REQUIRE_RS_SENDER`).** The campaign's PRIMARY sender is the Rust fork `srtla-send-rs` (ADR-003), CLI-identical to the C `srtla_send`. When `SRTLA_SEND_RS_BIN` resolves (env, or a `srtla_send_rs` on PATH) it replaces the C sender; `result.json` records `config.sender_kind` (`c`|`rust`) and `config.sender_bin`. `REQUIRE_RS_SENDER=1` makes a missing fork a clean SKIP (exit 77) rather than silently measuring the deprecated C sender as production. Default (both unset) keeps the C sender, so existing callers (`profile-validation-matrix.sh`) are unaffected (Rule E).

**FEC caller arm — `CALLER_PACKETFILTER`.** For the FEC arms of the gain hunt, `reorder-stress.sh` accepts `CALLER_PACKETFILTER` (an SRT FEC packet-filter config, must match `^fec,`). When set, the SRT caller switches from ffmpeg-direct to ffmpeg (MPEG-TS generator) piped into `srt-live-transmit` carrying `&packetfilter=<value>` — ffmpeg's libsrt wrapper has a fixed option allow-list with NO `packetfilter` (appending it hard-fails `Option not found`), while `srt-live-transmit` (libsrt 1.5.5) accepts it (same caller as `fec-connect-matrix.sh`). Pair with a FEC-accepting sink via `SINK_EXTRA_ARGS="--packetfilter fec"`; the negotiated filter lands in `result.json` as `sink.negotiated_packetfilter` and the requested filter as `config.caller_packetfilter`. Requires `srt-live-transmit` on PATH — absent ⇒ SKIP (exit 77). Pure FEC (`arq:never`) is refused; FEC is always an `arq:onreq` hybrid. Empty default = today's ffmpeg-direct caller, byte-identical (Rule E).

### Gain-hunt orchestrator (FEC×NAK×FREEZE)

`tests/compat/scenarios/gain-hunt-matrix.sh` is the ORCHESTRATOR for the receiver gain hunt — the campaign that decides whether any receiver recipe earns a place in the operator-facing receiver-capability catalog (which ships EMPTY). It fixes the pre-registered "real gain + no regression" decision rule in code (now including a `reverse_wire_amp ≤ 1.10×` guardrail), and enumerates a **3-axis candidate matrix: REORDERFREEZE × NAKREPORT × FEC** (2×2×2 = 8 tuples; the baseline tuple `freeze=1,nak=0,fec=off` = Classic L2 + latency is excluded → **7 candidates**). `LOSSMAXTTL=40` is held constant. FEC is **always** the `arq:onreq` hybrid (`fec,cols:16,rows:1,layout:even,arq:onreq`); pure FEC `arq:never` is BANNED and **REFUSED (exit 2)** in every mode (overridable spec via `GAIN_FEC_FILTER`, validated by `assert_no_arq_never`).

Modes:
- bare → notice + matrix summary (exit 0)
- `--dry-run` → prints the full 3-axis matrix with each cell's SRTO tuple (exit 0)
- `--smoke` → runs the falsifiability control FIRST, then ONE paired cell (candidate `f1-n1-plain` NAK-on vs baseline `f1-n0-plain`) bounded, writing per-rep `result.json`; a control that PASSES SKIPs (exit 77, instrument not falsifiable); needs CAP_NET_ADMIN **and** a resolvable `srtla-send-rs` (else SKIP exit 77)
- `--stage screen|deep` → the **two-stage** campaign (T-A6). `screen` sweeps all 7 candidates × a reduced adverse grid (`STEADY_LOSS_PCT ∈ {3,7}`, `BURST_LOSS_PCT ∈ {0,20}`) at `SCREEN_REPS=4` and emits `survivors.json` (a combo survives on a directional gain — `goodput ≥ 1.03×` OR `late-drop ≤ 0.80×` — in ≥1 cell with no hard-gate failure: `disconnects==0`, `ts_sync==0`). `deep` runs the **deep set = survivors ∪ top-K(2)/family ∪ the high-loss SENTINEL cells (`STEADY=7,BURST=20` per candidate, ALWAYS)** at `DEEP_REPS=10`, then runs `--analyze` across **every** deep cell and writes `verdict.json` (`promoted:[…]` or `NULL`). The sentinels are deep-tested even when the screen rejected them — the **anti-false-NULL rescue** (Oracle O4): a NULL is recorded only when the FULL deep set, sentinels included, shows no promotable candidate. Each stage runs a `PORT_MISMATCH=1` falsifiability control first and ABORTS (exit 2) if it passes. `--stage <s> --plan` prints the cell set with no privilege (the deep plan lists the sentinel cells for every family, incl. screen-rejected ones). Evidence lands under `test-results/gain-hunt/` (Rule D — gitignored, inside the repo)
- `--analyze <p>` → applies the pre-registered §2 decision-rule statistics to ALREADY-MEASURED paired evidence `<p>` and emits a verdict JSON to stdout. `<p>` is either a self-contained fixture JSON (`{candidate_id, cells:{<cell>:{candidate:[reps],baseline:[reps]}}}`) or a directory of `<cell>/{candidate,baseline}/rep-*.json` (the `run_cell` layout). It computes the **exact Mann-Whitney U** (pure-stdlib subset-sum permutation DP, two-sided `p = 2·P(U ≤ min(U, mn−U))`, tie-aware midranks; **no scipy** — it is absent on the box, only numpy + stdlib) for n ≤ 20, falling back to the tie-corrected normal approximation for larger n. It then applies **Holm-Bonferroni across every cell** in the supplied set (not just survivors), checks all seven no-regression guardrails per cell (`disconnects==0`, `ts_sync==0`, `ts_cc ≤ B`, `goodput ≥ 0.99×B`, `wire_amp ≤ 1.10×B`, `reverse_wire_amp ≤ 1.10×B`, `p95 pkt_rcv_drop ≤ B`), and promotes **only** with a Holm-significant real gain in ≥1 cell AND no regression in EVERY cell. Exit 0 = promoted, 1 = not promoted, 2 = no usable evidence. This COMPUTES a verdict over supplied evidence — it does not RUN the campaign (no CAP_NET_ADMIN, no sender needed).
- `--help` → header (exit 0); `--claim-gain` → REFUSED (exit 3), the falsifiability anchor — a gain cannot be claimed by running this script.

The PRIMARY sender is `srtla-send-rs` (resolved via `SRTLA_SEND_RS_BIN` or a `srtla_send_rs` on PATH); run modes pass `REQUIRE_RS_SENDER=1` to `reorder-stress.sh` so a missing fork SKIPs (exit 77) rather than measuring the C sender as production. Registered in `matrix.yaml` as `tier: informational` (NON-blocking; not run by `run-matrix.sh --tier`, which iterates pairs, not scenarios). Full protocol: [`docs/GAIN-HUNT-PROTOCOL.md`](docs/GAIN-HUNT-PROTOCOL.md). The adverse axes (STEADY_LOSS_PCT / BURST_LOSS_PCT / RTT_SPREAD_MS) remain additive on `reorder-stress.sh`; T-A6 wired the two-stage **structure** (screen→deep + sentinel rescue + falsifiability + verdict), and Wave B **already ran** it under CAP_NET_ADMIN, producing a **NULL** verdict (`test-results/gain-hunt/verdict.json`). Falsifiability self-test hooks (`GAIN_TEST_CONTROL_PASS` / alias `PORT_MISMATCH_PASS_OVERRIDE`, `GAIN_TEST_CONTROL_FAIL`) inject a synthetic control so the abort gate is verifiable without privilege.

FEC is **always** the `arq:onreq` hybrid at one pre-registered geometry — `fec,cols:16,rows:1,layout:even,arq:onreq` (column-only parity, ~6% overhead). The `cols≥16` floor is pre-registered (Oracle O5) so the forward FEC overhead (`1/cols`) stays clear of the `wire_amp ≤ 1.10×` budget *by construction*: `cols:16` ⇒ 6.25% (clear headroom), `cols:10` ⇒ 10% (on the cliff), `cols:8` ⇒ 12.5% (over budget). The campaign's NULL verdict is **first-class**: a NULL is recorded only when the FULL deep set — sentinels included — shows no promotable candidate under the §2 rule, with the stage's `PORT_MISMATCH` falsifiability control having FAILED first. Full protocol §3/§6: [`docs/GAIN-HUNT-PROTOCOL.md`](docs/GAIN-HUNT-PROTOCOL.md).

**Golden-fixture stats test.** `tests/compat/scenarios/gain-hunt-analyze-test.sh` pins the `--analyze` decision-rule engine against committed golden fixtures in `tests/compat/fixtures/gain-hunt-golden/` (`gain` → promoted; `regression` → rejected on the `disconnects` hard gate; `reverse-spam` → rejected on `reverse_wire_amp`; `tie` → `winner: none`). `expected.json` carries the by-hand exact statistic — when all 10 candidate goodput samples beat all 10 baseline samples, `U = m·n = 100`, `U_min = 0`, and `p = 2 / C(20,10) = 2/184756 ≈ 1.0825×10⁻⁵`; Holm over 2 such cells gives `≈ 2.165×10⁻⁵`. The test is pure-stdlib (no netem, no sender, no scipy) so it runs anywhere `python3` does.

**Geometry / wire-amp lint.** `tests/compat/scenarios/gain-hunt-geometry-lint.sh` is the executable form of the §3 geometry constraint: it reads the orchestrator's active `GAIN_FEC_FILTER` default, asserts its geometry is promotable (`cols≥16` AND `1/cols < 0.10`), and runs a discrimination self-test table (`cols:16` PASS, `cols:10`/`cols:8` REJECT) proving the budget check actually discriminates. A regression that narrows the FEC geometry to `cols:8` (~12.5% > the `wire_amp ≤1.10×` budget) trips this lint in CI rather than in a privileged campaign run. Pure stdlib (awk) — no netem, no sender, no scipy.

### FEC connect-matrix

`tests/compat/scenarios/fec-connect-matrix.sh` proves the one-sided FEC packet-filter negotiation behavior (direct SRT loopback; SRTLA is transparent UDP so negotiation is SRT-level). Four cases:

| Case | Caller filter | Listener filter | Result |
|------|--------------|-----------------|--------|
| (a) | FEC full config | `fec` (accept-form) | FEC negotiated — `packetfilter` non-empty |
| (b) | plain (no filter) | `fec` (accept-form) | PLAIN — responder clears filter, `packetfilter=""` |
| (c) | FEC full config | conflicting `fec,cols:20,rows:20` | HARD REJECT `SRT_REJ_FILTER` — `bytes_received=0` |
| (d) | FEC full config | no filter | ADOPTED — listener adopts caller config (informational) |

Cases (a)/(b)/(c) are gated; (d) is informational. Registered in `matrix.yaml` as scenario `fec-connect-matrix`. See `docs/COMPATIBILITY.md §6` for the full mechanism and empirical results.

**Key finding:** a listener with NO `packetfilter` does NOT reject a FEC caller — it adopts the caller's config (SRT `checkApplyFilterConfig` "good deal" else-branch). The genuine `SRT_REJ_FILTER` hard reject is a filter-config CONFLICT, not the absence of a filter. This is why L1 in `irl-srt-server` uses the accept-form `"fec"` and serves both FEC and non-FEC callers on the same port.

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

## RECEIVER CAPABILITY RECONCILIATION

Canonical decision record: [`docs/RECEIVER-RECONCILIATION.md`](../docs/RECEIVER-RECONCILIATION.md)

**`lossmaxttl` calibration result (Task 1 A/B): winner = 40** (BELABOX parity).

Both arms (30 vs 40) tied at `pkt_rcv_drop=0`, `ts_cc_errors=0`, equal goodput. The
pre-registered tie-break rule resolves to 40 (BELABOX parity / max compat). This value
is now locked into `irl-srt-server` L1 and L2 profiles (Task 4). Evidence:
`test-results/srt-receive-profiles/lossmaxttl-3040.json`.

**Gain-hunt orchestrator (Task 2, DONE):** `tests/compat/scenarios/gain-hunt-matrix.sh`
is the fully-wired two-stage screen→deep orchestrator for the pre-registered
adverse-config A/B protocol and candidate-mixture matrix. The campaign RAN under
CAP_NET_ADMIN with the `srtla-send-rs` sender and produced a **NULL** verdict (no
recipe cleared the gate; the catalog stays empty). Protocol doc: `docs/GAIN-HUNT-PROTOCOL.md`;
full mechanics and current status are in the "Gain-hunt orchestrator (FEC×NAK×FREEZE)"
section above. Registered in `matrix.yaml` as informational (non-blocking).

**FEC policy:** FEC is always `arq:onreq` hybrid; pure FEC (`arq:never`) is BANNED.
The mixture catalog is EMPTY until the gain-hunt evidence gate passes.

## ANTI-PATTERNS

- Don't modify the TS bindings API without checking `UPSTREAM MERGE STATUS` above — existing exports are frozen; new functionality must be additive
- Don't add `srtla` to `irl-srt-server` — it uses system libsrt directly, no srtla dep
- Don't confuse `srtla_send` (device) with `srtla_rec` (server/cloud)
- Don't extend the `node:child_process` debt in bindings — new code uses Bun-native APIs (`Bun.file`, `Bun.connect`)

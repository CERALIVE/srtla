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

The `irlserver/main` catch-up merge is **complete** (pinned at `aa66a88`, 63/63 ctest green). The `irlserver` remote is retained for future catch-ups. The TS bindings API is **settled** — safe to depend on. See `.cursor/plans/srtla-merge-upstream.plan.md` for the full merge record.

## STRUCTURE

```
srtla/
├── bindings/typescript/   # TS bindings for srtla_send / srtla_rec
│   ├── src/               # binding source
│   ├── dist/              # compiled output (consumed by CeraUI backend)
│   └── package.json       # package: @ceralive/srtla
├── docs/                  # protocol + ops docs (see below)
├── tests/compat/          # cross-impl compatibility harness (see COMPAT HARNESS)
└── CMakeLists.txt
```

## DOCS

Don't duplicate — read the source files:

| File | Content |
|------|---------|
| `docs/HOW_IT_WORKS.md` | Protocol internals, packet flow, connection groups |
| `docs/NETWORK_SETUP.md` | Multi-interface routing, NAT, firewall rules |
| `docs/TROUBLESHOOTING.md` | Common failure modes, diagnostics |
| `docs/keepalive-improvements.md` | NAT keepalive design notes |
| `docs/connection-info-comparison.md` | Per-connection quality tracking design |

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
- Pass criteria: handshake ≤5s, `bytes_received ≥ 1000`, `disconnects == 0`,
  clean SIGTERM teardown. The harness is falsifiable — `--scenario port-mismatch`
  must fail.

## ANTI-PATTERNS

- Don't modify the TS bindings API without checking `UPSTREAM MERGE STATUS` above — the API is settled; changes need deliberate versioning
- Don't add `srtla` to `irl-srt-server` — it uses system libsrt directly, no srtla dep
- Don't confuse `srtla_send` (device) with `srtla_rec` (server/cloud)

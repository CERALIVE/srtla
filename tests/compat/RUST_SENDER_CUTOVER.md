# ADR-003 Rust Sender (`srtla-send-rs`) Blocking-Tier Compat Run

**Date:** 2026-06-16 · **Sender under test:** `srtla-send-rs` **v1.0.0** ·
**Verdict:** ✅ Blocking-tier compat **PAIRS** all green (the ADR-003 cutover gate).

The shipping device sender moves from the C `srtla_send` to the Rust fork
[`srtla-send-rs`](https://github.com/CERALIVE/srtla-send-rs) (ADR-003). This run
exercises the SHA-verified **pre-built v1.0.0 release binary** against the C
`srtla_rec` (which stays — ADR-002) and the external ecosystem receivers, plus the
privileged netem behavioral scenarios. It is the reproducible, from-release-binary
counterpart of `SMOKE_BASELINE.md` (which baselined the *C* BELABOX sender).

---

## Subject under test (provenance + SHA256)

| Field | Value |
|-------|-------|
| Package | `srtla-send-rs_3.0.0_amd64.deb` (release `v1.0.0`, `gh release download v1.0.0 -R CERALIVE/srtla-send-rs`) |
| Recorded SHA256 (matrix.yaml:43) | `803f0ed4a8964d813a78e16cf2a1b84027fea6efc0273690b2cfa6a60a457dc5` |
| Downloaded `.deb` SHA256 | `803f0ed4a8964d813a78e16cf2a1b84027fea6efc0273690b2cfa6a60a457dc5` ✅ **MATCH** |
| Release `.sha256` sidecar | matches ✅ |
| Binary (`/usr/bin/srtla_send`, `ar x` + `tar --zstd`) | `3.0.0 (HEAD@b867c7d)` — matches matrix.yaml pin `b867c7d` |
| `Conflicts/Replaces` (control) | `srtla (<< 2026.7.0)` — `SRTLA_CUTOVER_VERSION` default |

The `.deb` package Version is `3.0.0` (inherited from the upstream Cargo.toml); pin
by SHA/commit, not version — exactly as the matrix.yaml note states.

**SHA verification is a hard gate**: the run aborts on mismatch, no silent fallback.

Receiver/helpers: locally-built `srtla_rec` + `srt-sink` + `ext-ka-probe`
(`cmake -B build -DBUILD_COMPAT_TESTS=ON`). The receiver was **not** modified.
Host: `x86_64`, passwordless sudo for the netem (CAP_NET_ADMIN) scenarios.

---

## Result 1 — blocking-tier compat PAIRS (the ADR-003 gate) ✅

Driven by `tests/compat/run-matrix.sh` with `SRTLA_SEND_RS_BIN=<extracted binary>`.
30 s measurement window. Pass criteria (per pair): handshake ≤ 10 s end-to-end first
byte, `bytes_received ≥ 1000`, `disconnects == 0`, clean SIGTERM teardown.

| Pair (matrix.yaml) | tier | bytes_received | first_byte | disc | teardown | Verdict |
|--------------------|------|---------------:|-----------:|-----:|----------|---------|
| `ceralive-srtla-send-rs` → `ours` (C `srtla_rec`) | blocking | 4,006,092 | 3115 ms | 0 | sink0/snd0/rcv143 | ✅ PASS |
| `ceralive-srtla-send-rs` → `belabox-srtla-rec` | blocking | 3,976,576 | 5404 ms | 0 | clean | ✅ PASS |
| `ceralive-srtla-send-rs` → `openirl-receiver` | blocking | 4,019,816 | 5207 ms | 0 | clean | ✅ PASS |

The fork↔C-receiver pair additionally detected the receiver's **extended-keepalive**
telemetry path (`ext_ka=true`), confirming the ADR-001 telemetry contract end to end.

### Falsifiability (negative control) — harness is not silently passing

`--scenario port-mismatch` against the same fork→C pair → **FAIL** as required
(`first_byte_ms=-1`, `bytes=0`, `handshake_ok=false`, harness exit 1). The PASS
verdicts above are therefore meaningful.

---

## Result 2 — privileged netem behavioral scenarios

Run against the fork by pointing `--build-dir` at a shadow dir whose `srtla_send`
is the v1.0.0 binary (`srtla_rec`/`srt-sink` are the local C build). `RUST_LOG=info`
so the fork (silent by default) emits its lifecycle log. netem single-leg shaping
selfcheck PASSED on this host (delta 100.0 ms for `delay 100ms`).

| Scenario | Topology | Verdict | Evidence |
|----------|----------|---------|----------|
| `reorder-stress` | 2 links, one `/29` | ✅ PASS | bytes 3,101,248, disc 0, 34 s, reorder phase active (2685 pkts) |
| `link-drop-high-rtt` | 2 links, one `/24`, 200 ms RTT | ✅ PASS | handshake 1252 ms, shift 887 ms, survivor up, 4,510,308 bytes, disc 0 |
| `jitter-stress` | 2 links, link #2 **cross-subnet** | ⚠️ host-limited | see below |

### `link-drop-high-rtt` required a harness fork-awareness fix (not a relaxation)

The scenario detects the post-isolation link shift by grepping the sender log. Its
shift-detection regex matched **only** the C wording `<ip> … connection failed`,
while the Rust fork logs the *same behavioral event* as
`via <ip> … timed out; attempting full socket reconnection`
(`src/sender/housekeeping.rs`). The fork **did** shift correctly (proven in its
log + survivor delivering 4.5 MB), but the C-only regex couldn't see it → false FAIL.

Fix: broaden the three shift-detection greps to the **dual-wording** form already
used by the sibling `link-drop.sh` (a documented sender-agnostic pattern; see
`srtla/AGENTS.md` → "The scenarios are sender-agnostic …"). The **pass gate is
unchanged** — only detection is taught the fork's equivalent wording. Verified:
fork now PASS (shift 887 ms); **C-sender regression check also PASS** (shift 670 ms),
since the new regex is a strict superset of the old one.

### `jitter-stress` — environment-limited on this dev host (NOT a fork regression)

`jitter-stress` is the only failing scenario. It is **not forced to pass** and was
**not relaxed**. Root cause is host-specific and affects both senders:

- **Failure:** `no_reaps_ok=false` — the C receiver reaped 14 connections
  (`conn_removed reason=timeout`) during the jitter window, violating the scenario's
  "jitter must never reap a healthy link" contract.
- **Root cause:** this scenario uniquely places link #2's source on a **different
  /30** (`10.174.x`) from the receiver (`10.173.x`). The receiver replies to link #2
  from its on-link `10.174.x` address, but the fork's `connect()`-ed UDP socket for
  that link only accepts datagrams from `10.173.219.2` → link #2's keepalive replies
  are dropped by the kernel's source-address selection on this host → the fork cycles
  link #2 through `marked for recovery; re-sending REG2` every ~6 s, and the receiver
  reaps the abandoned source ports. `reorder-stress` and `link-drop-high-rtt` (both
  **single-subnet**) pass cleanly, isolating the cause to the cross-subnet topology.
- **Not a fork regression:** the **C reference sender fails the same scenario
  *worse*** on this host (`bytes_received=0`, `total_size=0`, only 1 link ever in
  telemetry). The fork *outperformed* the C baseline (8.5 MB streamed, both links in
  telemetry 2/2/2, `disconnects==0`, strictly-increasing per-phase throughput) and
  failed *only* the zero-reaps assertion.
- **Determinism:** byte counts were byte-identical across three fork runs
  (2,886,740 / 5,846,424 / 8,823,216) and unchanged by `rp_filter=2` (loose) — so it
  is a deterministic topology/kernel-source-selection artifact, not flakiness or
  reverse-path filtering.
- **Where it is validated:** the privileged netem scenarios are designed for the CI
  netem environment (GitHub Actions `ubuntu-latest`, per `lib/netem.sh`); this
  cross-subnet keepalive path behaves there but not under this host's kernel source
  selection.

---

## Verdict

✅ **The ADR-003 Rust-sender blocking-tier compat PAIRS are all green** against the C
`srtla_rec` and the external receivers, with SHA-verified v1.0.0 binary and a passing
falsifiability control. `reorder-stress` and `link-drop-high-rtt` pass; `jitter-stress`
is environment-limited on this dev host for **both** senders (the C reference fails it
worse) and is not a fork regression — the fork outperforms the C baseline there.

Reproduce:

```bash
# 1. fetch + verify + extract the v1.0.0 binary
gh release download v1.0.0 -R CERALIVE/srtla-send-rs --pattern '*amd64*.deb'
sha256sum -c <<<'803f0ed4a8964d813a78e16cf2a1b84027fea6efc0273690b2cfa6a60a457dc5  srtla-send-rs_3.0.0_amd64.deb'
ar x srtla-send-rs_3.0.0_amd64.deb && tar --zstd -xf data.tar.zst ./usr/bin/srtla_send

# 2. build receiver + helpers
cmake -B build -DBUILD_COMPAT_TESTS=ON && cmake --build build -j

# 3. run the blocking-tier Rust-sender pairs
export SRTLA_SEND_RS_BIN="$PWD/usr/bin/srtla_send"
tests/compat/run-matrix.sh --pair ceralive-send-rsxours --duration 30
tests/compat/run-matrix.sh --pair ceralive-send-rsxbelabox-receiver --duration 30
tests/compat/run-matrix.sh --pair ceralive-send-rsxopenirl-receiver --duration 30

# 4. netem behavioral scenarios (need CAP_NET_ADMIN) — point at the fork binary
#    via a shadow build dir whose srtla_send is the v1.0.0 binary
sudo env RUST_LOG=info PATH="$PATH" bash tests/compat/scenarios/reorder-stress.sh --build-dir <forkdir>
sudo env RUST_LOG=info PATH="$PATH" bash tests/compat/scenarios/link-drop-high-rtt.sh --build-dir <forkdir>
```

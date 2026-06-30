# Gain-Hunt Protocol

Pre-registered adverse-config A/B protocol for the FEC-mixture **gain hunt**: the
campaign that decides whether any FEC packet-filter mixture earns a place in the
operator-facing receiver-capability catalog.

The catalog ships **empty**. Our shipping evidence is *parity*, not *gain* — the
BELABOX-parity baseline (Classic L2 + latency, ARQ always on) is proven equal to
the patched libsrt, and nothing beyond it is earned yet. A mixture is added to the
catalog **only** after this campaign produces evidence that clears the decision
rule below. This document is the gate; running the harness is how a candidate
tries to pass it.

- **Decision record:** [`../../docs/RECEIVER-RECONCILIATION.md`](../../docs/RECEIVER-RECONCILIATION.md) §"Gain-Hunt Protocol" and the L1–L3 locked decisions.
- **ADR cross-ref:** [`adr/ADR-002-srt-patch-necessity.md`](adr/ADR-002-srt-patch-necessity.md) — "C is SAFE": stock libsrt + `nakreport=0` + `lossmaxttl` is a proven baseline equivalent. The gain hunt borrows ADR-002's pre-registration discipline.
- **Harness scaffold:** [`../tests/compat/scenarios/gain-hunt-matrix.sh`](../tests/compat/scenarios/gain-hunt-matrix.sh) — orchestrator **stub** (this effort). It documents the rule and the matrix and **does not run the campaign** (R&D track).
- **Measurement instrument:** [`../tests/compat/scenarios/reorder-stress.sh`](../tests/compat/scenarios/reorder-stress.sh) — the same A/B instrument the profile-validation matrix uses, now extended with the adverse-config axes below.

> **Status:** PARTIALLY WIRED. The decision rule and candidate matrix are fixed
> here and in the orchestrator. The orchestrator now drives the instrument for a
> `--smoke` cell and the `--stage screen` FEC×NAK×FREEZE recipe matrix (REORDERFREEZE
> × NAKREPORT × FEC, baseline excluded → 7 candidates, `LOSSMAXTTL=40` held). The
> **§2 statistics engine now exists** as `--analyze`: it takes already-measured paired
> evidence and computes the verdict with an exact Mann-Whitney U (pure-stdlib — scipy
> is absent on the box) and Holm-Bonferroni across every cell (see §5). What remains
> for the R&D track (`--stage deep`, T-A6) is the deep adverse-axis + FEC-geometry
> data **collection** that feeds `--analyze`. See "Running the Full Campaign" for what
> completing it entails. The PRIMARY sender is `srtla-send-rs`; a run with no fork
> resolvable SKIPs (exit 77).

---

## 1. Why a Gain Hunt

FEC adds forward parity bytes so the receiver can reconstruct lost packets without
a retransmit round-trip. That overhead is only worth shipping if it buys a
measurable improvement under conditions the current compat matrix does not cover:
sustained loss, bursty (clustered) loss, and wide RTT spread across bonded links.
The current matrix proves *survival* under reorder; it does not search for a
*gain* under loss. The gain hunt is that search, run as a pre-registered A/B so a
positive result cannot be a post-hoc story.

Two non-negotiable constraints frame every candidate (locked in
`RECEIVER-RECONCILIATION.md` L2):

- **FEC is always `arq:onreq` hybrid** — FEC parity *plus* ARQ retransmit on
  demand. The ARQ floor is what makes FEC safe on lossy cellular.
- **Pure FEC (`arq:never`) is BANNED** across the entire stack. It trades latency
  for bytes with no retransmit floor and has regressed on every prior informal
  trial. It appears in the matrix **only** as a banned-control row the campaign
  asserts never promotes — never as a catalog candidate.

---

## 2. Pre-Registered Decision Rule — "real gain + no regression"

Fixed **before** any measurement exists (mirroring ADR-002). A candidate mixture
`C` is compared against the BELABOX-parity baseline `B` on a per-cell basis,
paired/alternating with a shared per-rep netem seed. `C` earns its catalog button
**iff both halves hold**:

### Real gain (C must WIN a primary metric, beyond noise)

`C` must beat `B` on at least one of:

- **goodput**: `median goodput_bps(C) ≥ 1.03 × median goodput_bps(B)` (≥3% up), **or**
- **late-drops**: `median pkt_rcv_drop(C) ≤ 0.80 × median pkt_rcv_drop(B)` (≥20%
  fewer late drops) **with goodput non-inferior** (`≥ 99%` of `B`).

The win must be statistically significant at `α = 0.05` (Mann-Whitney U), **Holm-
Bonferroni corrected** across all cells — not a single lucky rep.

### No regression (C must not LOSE a guardrail vs B)

In **every** cell:

| Guardrail | Condition |
|-----------|-----------|
| Disconnects | `disconnects == 0` in every `C` rep (hard gate — one disconnect = candidate out) |
| TS sync | `ts_sync_errors(C) == 0` |
| TS continuity | `ts_cc_errors(C) ≤ ts_cc_errors(B)` (median) |
| Goodput floor | `goodput_bps(C) ≥ 0.99 × goodput_bps(B)` (no goodput sold to buy drops) |
| Wire overhead | `wire_amp(C) ≤ 1.10 × wire_amp(B)` (FEC overhead bounded — the point of `arq:onreq` over pure FEC is to pay parity bytes only when they buy a gain) |
| Reverse overhead | `reverse_wire_amp(C) ≤ 1.10 × reverse_wire_amp(B)` (periodic-NAK's receiver→sender cost is bounded; the instrument meters `$PEERIF` egress inside the netns so this is no longer invisible) |
| Tail latency | `p95 pkt_rcv_drop(C) ≤ p95 pkt_rcv_drop(B)` |

### Verdict

A mixture earns its button **only** with **real gain in ≥1 adverse cell AND no
regression in EVERY cell**. A gain in one cell bought by a regression in another is
**not** a win. Ties and "equal" outcomes keep the baseline (catalog stays empty) —
the burden of proof is on the candidate. An un-earned mixture is not exposed in the
cloud capability descriptor or the CeraUI catalog.

---

## 3. Candidate-Mixture Matrix

FEC is always `arq:onreq`. Candidates vary the SRT packet-filter geometry only:

| id | packetfilter spec (caller side) | arq |
|----|--------------------------------|-----|
| `m-even-8x8` | `fec,cols:8,rows:8,layout:even` | `onreq` |
| `m-even-10x10` | `fec,cols:10,rows:10,layout:even` | `onreq` |
| `m-stair-8x8` | `fec,cols:8,rows:8,layout:staircase` | `onreq` |
| `m-stair-12x6` | `fec,cols:12,rows:6,layout:staircase` | `onreq` |
| `m-cols-only` | `fec,cols:10,rows:1,layout:even` (column-only parity) | `onreq` |
| (baseline) | *no packet filter — Classic L2 + latency, ARQ only* | n/a |
| (banned control) | `fec,cols:8,rows:8,layout:even,arq:never` | `never` — asserted to NEVER promote |

The even vs staircase layout and the cols/rows ratio trade reconstruction latency
against burst-loss coverage; column-only parity is the cheapest geometry and the
natural "does any FEC pay off at all" probe.

---

## 4. Adverse-Config Axes

Each candidate is swept across these axes, driving `reorder-stress.sh`. The axes
are additive env vars on that scenario — with all unset, the scenario is
byte-identical to its pre-axis behaviour (Rule E).

| Env var | Grid | Meaning |
|---------|------|---------|
| `STEADY_LOSS_PCT` | `{0, 1, 3, 7}` | Steady uniform packet loss % on **both** shaped links (`netem loss <pct>%`) |
| `BURST_LOSS_PCT` | `{0, 20}` | Bursty loss. With `STEADY_LOSS_PCT` it is the netem loss **correlation** % (`loss <steady>% <burst>%`); alone it drives the Gilbert-Elliott model (`loss gemodel <pct>%`) for clustered drops |
| `RTT_SPREAD_MS` | `{0, 150, 400}` | Extra one-way delay added to the **slow** link only, widening cross-link skew past the built-in 50/150 ms band (slow delay = `150 + RTT_SPREAD_MS`) |

A **cell** is one `(candidate, steady, burst, rtt)` point; the baseline is measured
in the **same** cell with the same seed. The default candidate-cell count is
`5 candidates × 4 × 2 × 3 = 120` candidate-cells, each paired with a baseline run.
`reorder-stress.sh` already sweeps bitrate (`BITRATE_KBPS`) and receive latency
(`RX_LATENCY_MS`); the gain hunt holds those at the production profile while
sweeping the loss/RTT axes, then spot-checks the winners across bitrates.

Where the axes pay off (the search hypothesis): FEC redundancy should pay under
high steady + bursty loss; a higher `lossmaxttl` should pay under extreme reorder;
wide RTT spread stresses the bonded reassembly window.

---

## 5. Using the Orchestrator

The orchestrator is falsifiable: it REFUSES `arq:never` in every mode (exit 2) and
**refuses to claim a gain** without the measured cross-cell campaign (exit 3).

```bash
# Print the notice + matrix summary (exit 0):
tests/compat/scenarios/gain-hunt-matrix.sh

# Print the full 3-axis FEC×NAK×FREEZE matrix + each cell's SRTO tuple (exit 0):
tests/compat/scenarios/gain-hunt-matrix.sh --dry-run

# The decision rule + candidate matrix in full (exit 0):
tests/compat/scenarios/gain-hunt-matrix.sh --help

# Run ONE paired cell (NAK-on candidate vs Classic baseline). Needs CAP_NET_ADMIN
# and a resolvable srtla-send-rs; SKIPs (exit 77) otherwise.
SRTLA_SEND_RS_BIN=/path/to/srtla_send_rs \
  tests/compat/scenarios/gain-hunt-matrix.sh --smoke --duration 8

# Run the full screen recipe matrix (7 candidate cells vs baseline):
SRTLA_SEND_RS_BIN=/path/to/srtla_send_rs \
  tests/compat/scenarios/gain-hunt-matrix.sh --stage screen --reps 6

# Apply the §2 decision-rule statistics to ALREADY-MEASURED paired evidence and emit a
# verdict JSON (exact Mann-Whitney U + Holm-Bonferroni; pure stdlib, no scipy, no
# privilege). <p> is a fixture JSON or a dir of <cell>/{candidate,baseline}/rep-*.json.
# Exit 0 = promoted, 1 = not promoted, 2 = no usable evidence.
tests/compat/scenarios/gain-hunt-matrix.sh --analyze tests/compat/fixtures/gain-hunt-golden/gain-fixture.json

# Attempt to assert a gain — REFUSED (exit 3). A gain cannot be claimed by running
# this script; only the cross-cell §2 stats (which --analyze implements, fed the
# T-A6 deep-stage evidence) may.
tests/compat/scenarios/gain-hunt-matrix.sh --claim-gain \
    --candidate f1-n1-fec \
    --baseline tests/compat/results/.../result.json \
    --decision-rule docs/GAIN-HUNT-PROTOCOL.md
```

The scenario is registered in
[`../tests/compat/matrix.yaml`](../tests/compat/matrix.yaml) as `tier:
informational` (NON-blocking). It never gates CI and is not executed by
`run-matrix.sh --tier` (which runs sender/receiver pairs, not scenarios).

### Sanity-check one adverse cell by hand

You can drive the instrument directly to feel out a single cell (still no verdict —
that needs the full paired campaign and the stats):

```bash
# Build the compat helpers, then one adverse reorder-stress run (needs CAP_NET_ADMIN):
cmake -B build -DBUILD_COMPAT_TESTS=ON && cmake --build build -j
STEADY_LOSS_PCT=3 BURST_LOSS_PCT=20 RTT_SPREAD_MS=150 \
  tests/compat/scenarios/reorder-stress.sh --duration 20
# Inspect tests/compat/results/reorder-stress/result.json -> .config / .metrics
```

---

## 6. Running the Full Campaign (Future R&D Track)

Implementing the campaign — explicitly **out of scope** for the scaffold effort —
means wiring `gain-hunt-matrix.sh` to:

1. **Build and pin each candidate's FEC libsrt geometry.** The device-side FEC
   packet-filter is only compiled when a FEC mixture is actively being earned
   (deferred per `RECEIVER-RECONCILIATION.md` "Out of Scope"). The receiver-side
   libsrt is swapped under `srt-sink` via `SINK_LD_LIBRARY_PATH`, exactly as
   `profile-validation-matrix.sh` swaps its baseline/freeze artifacts.
2. **Run `reorder-stress.sh` paired/alternating** (candidate vs baseline) per cell,
   with a shared per-rep `NETEM_SEED`, `N` reps each (start at `N=10`, matching the
   profile matrix), passing the FEC packetfilter to `srt-sink` via `SINK_EXTRA_ARGS`
   `--packetfilter`.
3. **Collect** `goodput_bps`, `pkt_rcv_drop`, `ts_sync_errors`, `ts_cc_errors`,
   `wire_amp`, `reverse_wire_amp`, `disconnects` from each run's `result.json`.
   (Steps 1–2 are partially wired: `--stage screen` already runs the FEC×NAK×FREEZE
   recipe matrix paired/alternating; the FEC-geometry sweep and the §4 deep
   adverse axes are the remaining `--stage deep` work, T-A6.)
4. **Apply the §2 rule** with the Holm-Bonferroni correction across cells. This step
   is **already implemented** as `gain-hunt-matrix.sh --analyze <p>` (exact Mann-
   Whitney U + Holm, pure stdlib — no scipy): point it at the collected per-cell
   `result.json` tree (`<cell>/{candidate,baseline}/rep-*.json`) and it emits the
   verdict JSON. The remaining T-A6 work is producing that evidence tree, not the
   statistics. The engine is pinned by the golden fixtures in
   `tests/compat/fixtures/gain-hunt-golden/` (validated by
   `tests/compat/scenarios/gain-hunt-analyze-test.sh`): a clean-separation gain (exact
   `U=100`, `p=2/C(20,10)≈1.0825×10⁻⁵`) promotes; a goodput win bought by a disconnect
   or by `reverse_wire_amp > 1.10×` is rejected naming the tripped guardrail; a tie
   yields `winner: none`.
5. **Emit** a results JSON + update the evidence table; on a pass, the cloud
   capability descriptor and the CeraUI catalog gain the entry. On anything short
   of a pass, the mixture stays out of the UI.

**Privilege:** the campaign needs `CAP_NET_ADMIN` (real root, passwordless sudo, or
mapped-root in a user+net namespace), gated via `tests/compat/lib/netem.sh`
`require`; without it the harness must SKIP (exit 77), never fabricate a
measurement. A `PORT_MISMATCH=1` falsifiability control run must precede the real
arms and must FAIL, proving the instrument can see a broken stream.

**Rule D:** all artifacts stay within the `srtla` repo
(`tests/compat/results/`, `test-results/`); nothing is written above the repo root.

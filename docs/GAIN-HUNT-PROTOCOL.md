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

> **Status:** WIRED (two-stage). The decision rule and candidate matrix are fixed
> here and in the orchestrator. The orchestrator now runs the campaign as a
> **two-stage screen→deep** sweep (T-A6): `--stage screen` sweeps all 7 candidates
> (REORDERFREEZE × NAKREPORT × FEC, baseline excluded, `LOSSMAXTTL=40` held) across a
> reduced adverse grid at low reps (=4) and emits the **survivors** set; `--stage
> deep` runs the **deep set = screen-survivors ∪ top-K(2)/family ∪ the high-loss
> SENTINEL cells (`STEADY_LOSS=7,BURST=20` per candidate, ALWAYS)** at reps=10, then
> applies `--analyze` across **every** deep cell and writes `verdict.json`. The
> sentinels are deep-tested even when the screen rejected them — the **anti-false-NULL
> rescue** (Oracle O4: a low-rep screen can miss a real effect at the directional
> survivor threshold; testing only survivors would then bury it as a FALSE NULL).
> Each stage runs a `PORT_MISMATCH=1` falsifiability control FIRST and ABORTS (exit 2)
> if it passes. The **§2 statistics engine** is `--analyze`: exact Mann-Whitney U
> (pure-stdlib — scipy is absent on the box) + Holm-Bonferroni across every cell (§5).
> What remains for the R&D track (Wave B) is **running** the campaign under
> `CAP_NET_ADMIN` to collect the evidence; T-A6 wired the structure, not the data. The
> PRIMARY sender is `srtla-send-rs`; a run with no fork resolvable SKIPs (exit 77).

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

# Run ONE paired cell (NAK-on candidate vs Classic baseline). The PORT_MISMATCH
# falsifiability control runs FIRST (must fail); a control that passes SKIPs (exit 77).
# Needs CAP_NET_ADMIN and a resolvable srtla-send-rs; SKIPs (exit 77) otherwise.
SRTLA_SEND_RS_BIN=/path/to/srtla_send_rs \
  tests/compat/scenarios/gain-hunt-matrix.sh --smoke --duration 8

# Print the planned cell set with NO privilege (nothing executed). The deep plan
# lists the SENTINEL cells for EVERY family — including screen-rejected ones — so you
# can see the anti-false-NULL rescue before committing a privileged run:
tests/compat/scenarios/gain-hunt-matrix.sh --stage screen --plan
tests/compat/scenarios/gain-hunt-matrix.sh --stage deep --plan

# STAGE 1 — screen: 7 candidates × a reduced adverse grid at low reps (=4); emits
# survivors.json (possibly empty). Falsifiability control first; ABORTS (exit 2) if it passes.
SRTLA_SEND_RS_BIN=/path/to/srtla_send_rs \
  tests/compat/scenarios/gain-hunt-matrix.sh --stage screen

# STAGE 2 — deep: deep set = survivors ∪ top-K(2)/family ∪ sentinels (ALWAYS) at
# reps=10, then --analyze across every deep cell -> verdict.json (promoted[...] or NULL).
SRTLA_SEND_RS_BIN=/path/to/srtla_send_rs \
  tests/compat/scenarios/gain-hunt-matrix.sh --stage deep

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

## 6. Running the Full Campaign (Wave B R&D Track)

The two-stage **structure** is wired (T-A6). What remains for Wave B is **running**
it under `CAP_NET_ADMIN` to collect evidence — the orchestrator already drives every
step below:

1. **Stage 1 — screen (`--stage screen`).** Runs all 7 candidates × a reduced adverse
   grid (`STEADY_LOSS_PCT ∈ {3,7}`, `BURST_LOSS_PCT ∈ {0,20}`) paired/alternating vs
   the Classic baseline at `SCREEN_REPS=4`, shared per-rep `NETEM_SEED`. A combo
   **survives** if it shows a directional gain (`goodput ≥ 1.03×` OR `late-drop ≤
   0.80×`) in ≥1 cell with **no hard-gate failure** (`disconnects==0`, `ts_sync==0`).
   Writes `screen-results.json` + `survivors.json` (survivors may be empty).
2. **Stage 2 — deep (`--stage deep`) with the anti-false-NULL rescue.** The deep set =
   **screen-survivors ∪ top-K(2)/family by directional effect size ∪ the high-loss
   SENTINEL cells (`STEADY_LOSS=7,BURST=20` per candidate, ALWAYS)**. An empty survivor
   set STILL deep-tests top-K + sentinels — a NULL verdict is recorded **only** when
   the full deep set, sentinels included, shows no promotable candidate. Runs at
   `DEEP_REPS=10`. This is Oracle O4's guard: a low-rep screen can miss a real effect
   at the directional survivor threshold, so testing only survivors would bury it as a
   FALSE NULL; the sentinels (where FEC should pay off) are re-tested at full power
   regardless of the screen outcome. `--stage deep --plan` prints the set without
   privilege — the sentinels appear for every family, including screen-rejected ones.
3. **FEC geometry / libsrt swap.** The device-side FEC packet-filter is only compiled
   when a mixture is actively being earned (deferred per `RECEIVER-RECONCILIATION.md`
   "Out of Scope"); the receiver-side libsrt is swapped under `srt-sink` via
   `SINK_LD_LIBRARY_PATH`. The screen/deep cells already pass the FEC packetfilter to
   `srt-sink` (via `SINK_EXTRA_ARGS --packetfilter`) on every FEC arm.
4. **Verdict — §2 rule, Holm-Bonferroni across the FULL deep set.** `--stage deep`
   runs `--analyze` over the whole deep tree (`<cell>/{candidate,baseline}/rep-*.json`)
   — exact Mann-Whitney U + Holm across **every** deep cell, not just survivors — and
   writes `verdict.json` (`promoted: [...]` or `verdict: NULL`). Each promoted combo
   carries `{combo, srt_flags, caller_packetfilter, nak, freeze, evidence_cells}`. The
   `--analyze` engine is pinned by the golden fixtures in
   `tests/compat/fixtures/gain-hunt-golden/` (validated by
   `tests/compat/scenarios/gain-hunt-analyze-test.sh`): a clean-separation gain (exact
   `U=100`, `p=2/C(20,10)≈1.0825×10⁻⁵`) promotes; a goodput win bought by a disconnect
   or by `reverse_wire_amp > 1.10×` is rejected naming the tripped guardrail; a tie
   yields `winner: none`.
5. **Promote.** On a pass the cloud capability descriptor and the CeraUI catalog gain
   the entry; on anything short of a pass the mixture stays out of the UI.

**Falsifiability:** each stage runs a `PORT_MISMATCH=1` control **before** the real
arms; it must FAIL (wrong receiver port ⇒ zero bytes ⇒ `pass:false`). A control that
PASSES proves the instrument cannot see a broken stream — the stage ABORTS (exit 2,
"instrument not falsifiable") and no verdict is trusted.

**Privilege:** the campaign needs `CAP_NET_ADMIN` (real root, passwordless sudo, or
mapped-root in a user+net namespace), gated via `tests/compat/lib/netem.sh`
`require`; without it the harness must SKIP (exit 77), never fabricate a
measurement. Evidence lands under `test-results/gain-hunt/` (screen/deep rep trees +
`screen-results.json`, `survivors.json`, `deep-results.json`, `verdict.json`).

**Rule D:** all artifacts stay within the `srtla` repo
(`tests/compat/results/`, `test-results/`); nothing is written above the repo root.

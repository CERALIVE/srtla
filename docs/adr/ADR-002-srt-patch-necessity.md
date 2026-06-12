# ADR-002: srt-patch Necessity Verdict and Omission Path

## Status

Accepted

## 1. Context

### The two patched-srt artifacts

Two distinct forks carry SRTLA-specific libsrt modifications:

**CERALIVE/srt** (`f5800cd` — the device-side fork, `srtcore/core.cpp`): a 6-line
unconditional merge that bakes three behaviors directly into the library at compile
time, with no runtime toggle:

| Behavior | Location | Effect |
|----------|----------|--------|
| (a) RTT log silenced | `srtcore/core.cpp:8717` | Suppresses a per-ACK byte-delivery-rate log line |
| (b) Reorder-tolerance decay disabled | `srtcore/core.cpp:10704, 10867` | Freezes `m_iReorderTolerance` — the receiver never increases its reorder window beyond the initial value |
| (c) Periodic NAK reports disabled | `srtcore/core.cpp:11451` | Suppresses the periodic NAK retransmit-request cycle; only loss-triggered NAKs fire |

These three behaviors are unconditional: any binary linked against CERALIVE/srt
gets all three regardless of socket options.

**irlserver/srt `belabox` branch** (the cloud-side fork): defines the compile-time
constant `SRTO_SRTLAPATCHES = 120`. This is a custom socket option that does not
exist in upstream Haivision/srt. Setting it on a socket activates the same
behaviors (b) and (c) at runtime, guarded by the option value.

The two forks are independent: CERALIVE/srt does NOT define `SRTO_SRTLAPATCHES`,
and irlserver/srt `belabox` does NOT carry the 6-line unconditional merge.

### Standard-option equivalents

The SRT standard API already exposes the same behaviors as options:

| Behavior | Standard option | Location in srt.h |
|----------|-----------------|-------------------|
| (c) Disable periodic NAK | `SRTO_NAKREPORT = 33` | `srtcore/srt.h:201` |
| (b) Freeze reorder tolerance | `SRTO_LOSSMAXTTL = 41` | `srtcore/srt.h:210` |

Behavior (a) is cosmetic (log suppression only) and has no standard-option
equivalent, nor does it need one.

### The consumers

Three components in the CeraLive stack could potentially depend on patched libsrt:

**srtla** (`srtla_send` / `srtla_rec`): a pure UDP striping proxy. It has no
libsrt linkage at all. The default CMake build (`BUILD_COMPAT_TESTS=OFF`) links
zero SRT symbols. The only place srtla links libsrt is the compat test helper
`srt-sink` (`BUILD_COMPAT_TESTS=ON`), which uses system libsrt and is a test
instrument, not a production binary. Patch behaviors (a), (b), (c) are entirely
irrelevant to srtla.

**cerastream**: the Rust streaming engine. It links libsrt via pkg-config and uses
only the vanilla socket options documented in the upstream SRT API. It sets no
SRTLA-specific options and does not consume `SRTO_SRTLAPATCHES`. Patch behaviors
are irrelevant to cerastream.

**irl-srt-server** (cloud-only, not in the device image): the SOLE consumer of
`SRTO_SRTLAPATCHES`. `src/core/SLSSrt.cpp:247` calls:

```cpp
status = srt_setsockopt(fd, SOL_SOCKET, SRTO_SRTLAPATCHES, &srtlaPatchesValue, sizeof(srtlaPatchesValue));
```

This is the only call site in the entire codebase. `irl-srt-server` must currently
be built against irlserver/srt `belabox` because `SRTO_SRTLAPATCHES` does not
exist in upstream Haivision/srt; building against stock libsrt fails to compile.

---

## 2. Evidence

### Evaluation design

The question is: can vanilla libsrt + standard SRT options (condition C) safely
replace the custom srt-patch (condition A) on the receiver side?

Three conditions were evaluated across 18 runs (6 reps each, each run ≥60 s) using
`tests/compat/scenarios/reorder-stress.sh` under asymmetric-delay reorder stress
(50 ms vs 150 ms striping on a bonded `prio` qdisc, plus an explicit
`netem reorder 25% 50% delay 20ms` phase on the fast link):

| Cond | libsrt / flags | Role |
|------|----------------|------|
| **A** | patched CERALIVE/srt `52057f6` (`libsrt.so.1.5.4`) / defaults | Reference baseline |
| **B** | vanilla Haivision/srt `c39196c` (`libsrt.so.1.5.5`) / defaults | Unpatched control |
| **C** | vanilla Haivision/srt `c39196c` (`libsrt.so.1.5.5`) / `nakreport=0 lossmaxttl=30` | Standard-flag equivalent |

Identity was proven per run via `ldd`-resolved `.so` path (authoritative) and
effective-flags banner from the `srt-sink` instrument. `.so` sha256: vanilla
`3374288...` vs patched `12219000...` (worktree manifest, same git refs as the
build matrix). All 18/18 runs passed integrity checks.

Wire-compat note: `srtla_send` is libsrt-free (pure UDP proxy), so the only
meaningful patched/vanilla swap is receiver-side. `srt-sink` stands in for
`irl-srt-server` and exercises `SRTO_NAKREPORT`/`SRTO_LOSSMAXTTL` directly rather
than `SRTO_SRTLAPATCHES` (an honest approximation limit: the patched libsrt under
evaluation is CERALIVE/srt `52057f6`, which does not define `SRTO_SRTLAPATCHES`).

### Pre-registered decision rule (quoted verbatim, fixed before data collection)

> C is **SAFE** if: median goodput(C) ≥ 95% of A AND disconnects(C)==0 AND
> retransmit-rate(C) ≤ 1.5× A across both stress phases. Otherwise: **UNSAFE**.
> This rule is fixed BEFORE looking at data (no post-hoc threshold selection).

### Per-condition medians

| Cond | libsrt / flags | Median goodput (B/s) | Disconnects (all 6 runs) | Median wire-B/goodput | Median wire-pkt/goodput-KB |
|------|----------------|----------------------|--------------------------|----------------------|---------------------------|
| **A** | patched 1.5.4 / default | **94 274** | **0** | **1.1939** | **1.5674** |
| **B** | vanilla 1.5.5 / default | 94 297 | 0 | 1.3254 | 1.6511 |
| **C** | vanilla 1.5.5 / `nakreport=0 lossmaxttl=30` | **94 146** | **0** | **1.6584** | **1.7189** |

Goodput is within 0.2% across all conditions. The 1.2 s SRT receive-latency window
lets every variant fully recover the fixed-rate stream with zero disconnects; the
conditions differ only in forward-wire retransmit amplification.

### Per-run raw data (all 18 runs)

| Cond | Rep | Goodput B/s | Bytes recv | Disc | Dur s | Wire bytes | Wire pkt | Wire-B/goodput |
|------|-----|-------------|------------|------|-------|------------|----------|----------------|
| A | 1 | 94252 | 5843604 | 0 | 62 | 6987966 | 9180 | 1.1958 |
| A | 2 | 94252 | 5843604 | 0 | 62 | 6962644 | 9102 | 1.1915 |
| A | 3 | 94252 | 5843604 | 0 | 62 | 6965722 | 9126 | 1.1920 |
| A | 4 | 94349 | 5849620 | 0 | 62 | 7028528 | 9220 | 1.2015 |
| A | 5 | 94349 | 5849620 | 0 | 62 | 6949188 | 9204 | 1.1880 |
| A | 6 | 94297 | 5846424 | 0 | 62 | 7011276 | 9143 | 1.1992 |
| B | 1 | 94297 | 5846424 | 0 | 62 | 8226528 | 9902 | 1.4071 |
| B | 2 | 94297 | 5846424 | 0 | 62 | 7669484 | 9595 | 1.3118 |
| B | 3 | 94252 | 5843604 | 0 | 62 | 7892158 | 9706 | 1.3506 |
| B | 4 | 94297 | 5846424 | 0 | 62 | 7651846 | 9508 | 1.3088 |
| B | 5 | 94297 | 5846424 | 0 | 62 | 7585710 | 9495 | 1.2975 |
| B | 6 | 94297 | 5846424 | 0 | 62 | 7828116 | 9717 | 1.3390 |
| C | 1 | 94146 | 5837024 | 0 | 62 | 9269660 | 9800 | 1.5881 |
| C | 2 | 94146 | 5837024 | 0 | 62 | 9515212 | 9920 | 1.6301 |
| C | 3 | 94146 | 5837024 | 0 | 62 | 9825616 | 10228 | 1.6833 |
| C | 4 | 94146 | 5837024 | 0 | 62 | 9858548 | 10122 | 1.6890 |
| C | 5 | 94146 | 5837024 | 0 | 62 | 9535102 | 9945 | 1.6336 |
| C | 6 | 94146 | 5837024 | 0 | 62 | 9861550 | 10135 | 1.6895 |

`goodput = bytes_received / duration_s`. `wire bytes`/`wire pkt` = cumulative egress
on the bonded `prio` root qdisc (`veth-reord`), last `tc -s qdisc show` snapshot per
run. The retransmit-rate proxy is a forward-wire amplification ratio (total egress /
delivered goodput); per-packet header overhead and srtla control are constant across
conditions, so cross-condition variation tracks retransmission volume.

### Verdict — applying the rule to C vs A

| Clause | Requirement | Measured | Pass |
|--------|-------------|----------|------|
| 1 | median goodput(C) ≥ 95% of A | 94 146 ≥ 0.95 × 94 274 = 89 561 (C/A = **99.9%**) | ✅ |
| 2 | disconnects(C) == 0 (both phases) | max disconnects over all 6 C runs = **0** | ✅ |
| 3 | retransmit-rate(C) ≤ 1.5× A (bytes proxy) | 1.6584 ≤ 1.5 × 1.1939 = 1.7909 (C/A = **138.9%**) | ✅ |
| 3 (alt) | retransmit-rate(C) ≤ 1.5× A (pkts proxy) | 1.7189 ≤ 1.5 × 1.5674 = 2.3511 (C/A = **109.7%**) | ✅ |

**VERDICT: condition C is SAFE.**

All three pre-registered clauses pass. The verdict is robust to proxy choice and to
worst-case run selection: even C's worst single-run byte-proxy (1.6895) vs A's best
(1.1880) = 1.422× ≤ 1.5×.

Clause 3 is the binding one. The ordering A < B < C on the byte-proxy shows the
custom patch genuinely minimises forward-wire retransmit amplification best, and
vanilla + standard flags does not byte-for-byte reproduce it. But the gap stays
inside the pre-registered 1.5× tolerance, goodput is identical, and disconnects are
zero. On the agreed safety criteria, standard flags are a SAFE substitute for the
patch under cross-link reorder stress. The cleaner packet-count proxy puts C only
+9.7% over A.

### Measurement limits (stated honestly)

1. **No native retransmit counter.** The retransmit-rate clause uses a forward-wire
   amplification proxy (egress bytes or packets / delivered goodput). The byte proxy
   is additionally inflated by netem-reorder requeue byte-accounting on the fast link
   during phase ii (present equally in all conditions). Both proxies independently
   yield the SAFE verdict.

2. **Wire-compat mix is receiver-side only by architecture.** `srtla_send` is
   libsrt-free; the only libsrt in the data path is on the receiver side. `srt-sink`
   stands in for `irl-srt-server` and exercises `SRTO_NAKREPORT`/`SRTO_LOSSMAXTTL`
   rather than `SRTO_SRTLAPATCHES`. The patched libsrt under evaluation (CERALIVE/srt
   `52057f6`) does not define `SRTO_SRTLAPATCHES`.

3. **Phases are sequenced within each run, not measured separately.** The instrument
   emits one whole-run summary. `reorder_pkts` and `slow_link_pkts` independently
   prove phase ii was active in every run; `disconnects == 0` holds for both phases.

---

## 3. Decision

### Per-behavior verdict

| Behavior | Description | Verdict |
|----------|-------------|---------|
| (a) RTT log silenced (`core.cpp:8717`) | Suppresses a per-ACK byte-delivery-rate log line | **COSMETIC** — no functional effect on stream delivery |
| (b) Reorder-tolerance decay disabled (`core.cpp:10704, 10867`) | Freezes `m_iReorderTolerance` | **REPLACEABLE** by `SRTO_LOSSMAXTTL=30` (`srt.h:210`) |
| (c) Periodic NAK disabled (`core.cpp:11451`) | Suppresses periodic NAK retransmit-request cycle | **REPLACEABLE** by `SRTO_NAKREPORT=0` (`srt.h:201`) |

### Per-consumer necessity verdict

| Consumer | libsrt linkage | Uses `SRTO_SRTLAPATCHES` | Patch behaviors relevant | Verdict |
|----------|---------------|--------------------------|--------------------------|---------|
| **srtla** | None (pure UDP proxy) | No | No | **PATCH NOT NEEDED** |
| **cerastream** | Via pkg-config, vanilla options only | No | No | **PATCH NOT NEEDED** |
| **irl-srt-server** | irlserver/srt `belabox` (required to compile) | Yes — sole consumer at `SLSSrt.cpp:247` | (b) and (c) active via `SRTO_SRTLAPATCHES`; (a) not present | **REPLACEABLE** — behaviors (b) and (c) have standard-option equivalents; (a) is cosmetic |

The empirical SAFE verdict (Section 2) authorizes the replacement: vanilla libsrt
with `SRTO_NAKREPORT=0` and `SRTO_LOSSMAXTTL=30` delivers equivalent stream quality
under reorder stress within the pre-registered tolerance.

---

## 4. Omission Path

The SAFE verdict authorizes removing the dependency on patched libsrt. The path has
two steps with different owners and timelines.

### Step 1 — irl-srt-server: replace `SRTO_SRTLAPATCHES` with standard options (Task 20, this plan)

**Authorized by this ADR.** The change is an `#ifdef`-guarded replacement in
`src/core/SLSSrt.cpp`:

- Where `SRTO_SRTLAPATCHES` is currently set (line 247), replace with two
  `srt_setsockopt` calls: `SRTO_NAKREPORT = 0` and `SRTO_LOSSMAXTTL = 30`.
- Guard with `#ifdef SRTO_SRTLAPATCHES` so the build still compiles against the
  irlserver/srt `belabox` branch during the transition period.
- Once the standard-option path is in place, `irl-srt-server` can be built against
  upstream Haivision/srt without the belabox branch.

**Owner:** Task 20 (irl-srt-server PR4 in this plan).

### Step 2 — device image: adopt vanilla libsrt (FOLLOW-UP, explicitly out of this plan)

The device image currently ships CERALIVE/srt (the 6-line unconditional merge).
Switching the device image to vanilla Haivision/srt requires:

1. Updating `image-building-pipeline` to pull from Haivision/srt instead of
   CERALIVE/srt.
2. Verifying that `cerastream` (which links libsrt via pkg-config) builds and
   passes its test suite against vanilla libsrt.
3. Running the full compat harness (`tests/compat/run-matrix.sh --tier blocking`)
   against the new device image.

This step is explicitly deferred. The CERALIVE/srt fork remains the device-image
libsrt until a dedicated follow-up plan completes it.

### Wire-compat statement for mixed deployments

The empirical data covers the receiver-side swap only (by architecture: `srtla_send`
is libsrt-free). A deployment where `irl-srt-server` runs vanilla libsrt +
standard flags while devices still ship patched libsrt is safe within the measured
caveats:

- Goodput is within 0.2% of the patched baseline (99.9% C/A).
- Disconnects remain zero across all 18 runs under reorder stress.
- Retransmit amplification on the receiver side increases by up to 38.9% (bytes
  proxy) or 9.7% (packets proxy) vs the patched baseline. This is inside the
  pre-registered 1.5× tolerance and does not affect delivered stream quality.
- The measurement does not cover the case where both sender and receiver run vanilla
  libsrt simultaneously (device-image migration, Step 2). That combination requires
  its own evaluation before Step 2 is authorized.

---

## 5. Consequences

### What stays forked and why

**CERALIVE/srt fork** remains the device-image libsrt until Step 2 (device-image
vanilla adoption) is completed. The fork carries the 6-line unconditional merge;
behaviors (a), (b), (c) remain active on the device side. This is acceptable: the
SAFE verdict shows the receiver can safely run vanilla + standard flags while the
device side remains patched.

**irlserver/srt `belabox` branch** remains the required build dependency for
`irl-srt-server` until Task 20 lands. After Task 20, `irl-srt-server` can be built
against upstream Haivision/srt, and the `belabox` branch dependency is retired for
that component.

### Maintenance burden

**With the patch (current state):**
- `irl-srt-server` must be built against irlserver/srt `belabox` — a non-upstream
  branch that requires manual tracking and periodic rebase against Haivision/srt
  releases.
- `SRTO_SRTLAPATCHES` is a compile-time constant that does not exist in upstream
  libsrt; any upstream libsrt upgrade requires a corresponding belabox-branch update.
- CERALIVE/srt must be kept in sync with Haivision/srt releases while carrying the
  6-line merge.

**After Task 20 (irl-srt-server on vanilla libsrt):**
- `irl-srt-server` tracks upstream Haivision/srt directly. No custom branch needed.
- `SRTO_NAKREPORT` and `SRTO_LOSSMAXTTL` are stable upstream options; no custom
  maintenance required.
- CERALIVE/srt fork maintenance burden is unchanged until Step 2.

**After Step 2 (device image on vanilla libsrt):**
- Both components track upstream Haivision/srt. The CERALIVE/srt fork can be
  archived. Maintenance burden drops to zero for the libsrt layer.

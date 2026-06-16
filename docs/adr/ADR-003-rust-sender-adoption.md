# ADR-003: Adopt irlserver srtla_send (Rust) via CERALIVE Fork

## Status

Accepted

## 1. Context

### The upstream Rust sender

[irlserver/srtla](https://github.com/irlserver/srtla) ships a Rust rewrite of
`srtla_send` alongside the original C receiver. As of the evaluation snapshot
(v3.0.0, 206 commits, MIT license):

- **Runtime:** tokio async Rust, single binary, no C runtime dependency
- **Test coverage:** 3619 LOC of tests (unit + integration)
- **Bonding modes:** classic (round-robin), enhanced (quality-weighted), and
  rtt-threshold (switches to single-link below an RTT threshold)
- **Schedulers:** EDPF (Early Departure Point Fair), BLEST (Blocking Estimation),
  IoDS (Instant Optimal Delivery Scheduling) — selectable at runtime
- **RTT estimation:** Kalman filter replacing the C sender's hardcoded `rtt_ms = 0`
- **Smart exploration:** probes underused links periodically to detect recovery
- **Control surface:** stdin commands + Unix domain socket for runtime control

The C sender in our fork (`srtla_send`) has none of these scheduler variants,
no Kalman RTT filter, and no Unix control socket. The Rust sender is a
materially better piece of software for the sender role.

### Why adopt rather than port or rewrite

Porting the scheduler suite and Kalman filter to C would be a large, risky
undertaking with no test suite to land on. Writing our own Rust sender from
scratch would duplicate the upstream effort and start with zero test coverage.
The upstream Rust sender already has 3619 LOC of tests and a stable v3.0.0
release. Forking and maintaining parity is the lowest-risk path to the
scheduler and RTT improvements.

### The parity contract

CeraUI drives `srtla_send` through the `@ceralive/srtla` TypeScript bindings.
The bindings encode two contracts that the Rust sender must honour:

**CLI positional order** (frozen in `srtlaSendOptionsSchema`):
```
srtla_send <listen_port> <srtla_host> <srtla_port> <ips_file> [--verbose] [--stats-file <path>]
```

**ADR-001 telemetry schema** (JSON stats file, atomic `rename(2)`, 1000 ms cadence):
```json
{
  "schema_version": 1,
  "last_updated_ms": 1749556546000,
  "connections": [
    {
      "conn_id": "0",
      "rtt_ms": 42,
      "nak_count": 3,
      "weight_percent": 85,
      "window": 8192,
      "in_flight": 100,
      "bitrate_bps": 2500000
    }
  ]
}
```

`bitrate_bps` is wire bytes/s × 8 (bits per second). `conn_id` is assigned by
ips-file order and is stable until SIGHUP reload.

### Receiver stays in C

ADR-002 established that the C receiver (`srtla_rec`) is safe to run against
vanilla libsrt with standard options. The receiver is well-tested, stable, and
has no scheduler complexity. There is no motivation to replace it. This ADR
covers the sender only.

### License compatibility

irlserver/srtla is MIT licensed. CeraLive/srtla is AGPLv3. Incorporating MIT
code into an AGPLv3 project is permitted: MIT is a permissive license that
imposes no copyleft restrictions on the incorporating work. The resulting fork
is AGPLv3 as a whole. The one-way restriction runs the other direction:
upstreaming our AGPLv3 additions back to the MIT-licensed irlserver repo would
require them to accept AGPLv3 terms, which they are not obligated to do. We
can take from them freely; they cannot take our AGPLv3 additions without
explicit relicensing.

---

## 2. Options Considered

### Option A: Feature-port scheduler suite to C sender

Implement EDPF/BLEST/IoDS schedulers and the Kalman RTT filter in the existing
C `srtla_send`.

**Rejected.** The C sender has no scheduler abstraction layer; adding three
scheduler variants plus a Kalman filter is a large, invasive C change. The
upstream Rust implementation already has 3619 LOC of tests covering these
paths. Reimplementing in C produces no test suite, no scheduler abstraction,
and no benefit over the upstream work. The maintenance burden would be ours
alone with no upstream to pull from.

### Option B: Own Rust rewrite from scratch

Write a new Rust `srtla_send` without forking the upstream.

**Rejected.** This duplicates the upstream effort entirely. The irlserver Rust
sender is already at v3.0.0 with 206 commits of refinement and 3619 LOC of
tests. Starting from scratch means starting with zero test coverage and
re-solving problems the upstream has already solved. There is no advantage over
forking.

### Option C: Fork irlserver Rust sender, add parity layer, direct cutover

Fork the `irlserver/srtla` Rust sender into a CERALIVE-maintained repo. Add a
parity layer that satisfies the CLI contract and ADR-001 telemetry schema.
Gate the cutover on the compat matrix passing with the Rust sender and a CeraUI
skew test. Retire the C sender's GTest suites from the `.deb` at cutover but
keep them in the source tree.

**Selected.** See Decision below.

---

## 3. Decision

**Adopt Option C: fork the irlserver Rust sender, add a parity layer, and cut
over directly. No dual-shipping.**

### Fork and parity layer

The fork lives at `github.com/CERALIVE/srtla-send-rs` (separate repo, not a
subdirectory of the C srtla repo). The parity layer adds:

1. **CLI argument parsing** matching the positional order above exactly. The
   upstream Rust sender uses a different argument layout; the parity layer
   wraps or replaces it to match the frozen `srtlaSendOptionsSchema` contract.

2. **ADR-001 telemetry serializer** writing the JSON stats file at the path
   given by `--stats-file`, atomically via `rename(2)`, every 1000 ms. The
   `schema_version: 1` field is added (not present in the upstream sender).
   `rtt_ms` is populated from the Kalman filter output (an improvement over
   the C sender's hardcoded `0`).

3. **Binary name:** the output binary must be named `srtla_send` exactly.

### Divergences from the C sender (documented, not bugs)

| Field / behavior | C sender | Rust sender (this fork) | Classification |
|------------------|----------|-------------------------|----------------|
| `rtt_ms` in telemetry | Hardcoded `0` (wire struct not populated by C sender) | Kalman-filtered RTT from the Rust scheduler | **Improvement** — consumers get real RTT data |
| `schema_version` in telemetry JSON | Absent | `1` (added by parity layer) | **Additive** — consumers that ignore unknown fields are unaffected; the ADR-001 schema always included this field |
| `conn_id` stability across SIGHUP | Stable (ips-file order, no reorder) | May shift if IPs reorder in the file on reload | **Known limitation** — conn_ids are assigned by ips-file order; a SIGHUP that reorders IPs in the file will reassign conn_ids. CeraUI writes the ips file and controls ordering; it must not reorder existing IPs on reload. Documented here, not fixed at cutover. |

### Keepalive cadence and jitter penalty (verified — Task 12)

PR #19 (srtla receiver hardening) established a 1 s keepalive cadence and a
jitter penalty relative to mean RTT. The Rust sender's keepalive behavior and
its interaction with the receiver's jitter scoring were verified end-to-end
under network namespaces in Task 12. Both behaviors reproduce the C sender's
*outcomes*; the keepalive cadence matches within the integer-second tolerance C
itself has, and jitter demotion is achieved through the fork's own scheduler
rather than a ported penalty formula. Full equivalence tables, measured numbers,
and divergence verdicts are in the **Appendix** below. The compat matrix gate
(see Cutover Gate below) remains the cutover backstop.

### Upstream-merge policy

Upstream (`irlserver/srtla` Rust sender) is tracked manually. Merges are
gated on the compat matrix passing with the merged version. Merges are never
automated. The parity layer is maintained as a diff on top of upstream; merge
conflicts in the parity layer are resolved manually before the compat gate
runs.

### Cutover gate

The C sender is retired from the `.deb` when both of the following pass:

1. **Compat matrix** (`tests/compat/run-matrix.sh --tier blocking`) passes with
   the Rust sender in the sender role across all blocking pairs.
2. **CeraUI skew test** confirms the Rust sender's telemetry output parses
   correctly through the `readSenderTelemetry` binding and the NetworkView
   broadcast loop.

Until both gates pass, the C sender remains the shipped binary.

### GTest sender suites at cutover

The C sender's GTest suites (`test_sender_bootstrap.cpp`, and any other suites
that exercise `srtla_send` directly) are **retired from the `.deb` build** at
cutover — they test a binary that is no longer shipped. They are **not deleted
from the source tree**. They remain as historical reference and as a regression
baseline if the C sender is ever revived.

---

## 4. Consequences

### Two-language split

After cutover the srtla repo ships a C receiver and a Rust sender. This is a
deliberate split: the receiver has no motivation to change, and the sender
benefits materially from the Rust implementation. The split is documented here
and in `AGENTS.md` so future contributors understand it is intentional.

### Bus-factor mitigation

The Rust sender introduces a second language to the srtla surface. Contributors
who know only C can still maintain the receiver. Contributors who know only Rust
can maintain the sender. The parity layer is the critical seam: it must be
understood by whoever owns the fork. Bus-factor mitigation is needed: at minimum
one additional contributor should be familiar with the parity layer before the
cutover lands in a production release.

### Scheduler and control-socket UI exposure

The Rust sender's EDPF/BLEST/IoDS scheduler selection and Unix control socket
are available at the binary level after the fork. Exposing scheduler selection
and the control socket through CeraUI is **explicitly out of scope for this
plan**. It is noted here as future work. The parity layer does not block or
prevent it; it simply does not wire it up.

### Telemetry improvement

`rtt_ms` will contain real Kalman-filtered RTT values instead of `0`. CeraUI's
NetworkView will display meaningful per-link RTT data for the first time. No
schema change is required; the field was always defined in ADR-001.

### C sender GTest suites

`test_sender_bootstrap.cpp` and related sender-focused suites remain in the
source tree after cutover. They are excluded from the `.deb` build target but
are not deleted. The receiver suites (`test_registration_handshake.cpp`,
`test_extended_keepalive.cpp`, `test_reg_race.cpp`, `test_group_limits.cpp`,
`test_ghost_group_eviction.cpp`, `test_timeout_cleanup.cpp`,
`test_identity_hooks.cpp`, `test_telemetry_emit.cpp`) are unaffected and
continue to gate every release.

---

## Appendix: PR #19 sender-behavior parity verification (Task 12)

The two PR #19 behaviors flagged above were verified end-to-end against a live C
`srtla_rec`, two bonded uplinks in a network namespace, and a real SRT data
stream. Selection share is read directly off the wire: each forwarded packet
carries the source IP of the uplink the sender chose, so grouping captured
packets by source IP yields the true per-link selection share regardless of
egress routing. The verification lives in the fork as an opt-in netns suite
(`tests/netns_pr19_parity.rs` in `srtla-send-rs`); it skips cleanly without
root/netem/`srtla_rec`, so the default CI gate is unaffected.

Reference C behavior: `src/sender_logic.h` (`SENDER_IDLE_TIME`, `keepalive_due`)
and the receiver jitter scoring retuned in PR #19 (`RTT_JITTER_RATIO_HIGH/SEVERE`
in `src/receiver_config.h`).

### Behavior 1 — per-connection keepalive cadence

| Dimension | Value |
|-----------|-------|
| C behavior | Idle link pinged when `keepalive_due(last_sent, now)` → `(last_sent + 1) < now`, with whole-second `time_t`. `SENDER_IDLE_TIME = 1 s`. Receiver mirrors this with `KEEPALIVE_PERIOD = 1 s` paced by a per-connection `last_keepalive_sent` stamp (the PR #19 housekeeping decoupling). |
| Fork mechanism | `SrtlaConnection::needs_keepalive()` → `last_keepalive_sent.elapsed().as_secs() >= IDLE_TIME` (`IDLE_TIME = 1`), with a per-connection `last_keepalive_sent: Option<Instant>` stamp, fired from the 1 s housekeeping tick (`HOUSEKEEPING_INTERVAL_MS = 1000`). Keepalives are sent unconditionally per connection (Moblin-style) and carry extended telemetry (window, RTT, NAKs, bitrate) to the receiver. |
| Verified outcome | Measured per-uplink cadence under load: median **1.001 s**, max gap **2.001 s**, ~0.68 keepalive rounds/s; both links identical. A separate run measured a 2.000 s median — the cadence is bimodal ~1–2 s. It never approaches `CONN_TIMEOUT` (5 s), so NAT mappings and telemetry liveness are preserved. |
| Divergence verdict | **EQUIVALENT.** Both implementations target 1 s and both exhibit an effective ~1–2 s cadence: the integer-second floor (`as_secs()` in the fork, whole-second `time_t` in C's `(last_sent + 1) < now`) interacting with a periodic check pushes the next ping out by up to one extra second. The fork uses sub-second `Instant` deltas but still floors them, so it is no looser than C. One deliberate, additive difference: the fork sends keepalives on every active link *even under data load* to feed receiver telemetry, whereas the C `keepalive_due` path only pings *idle* links. This adds telemetry, it does not regress liveness. |

### Behavior 2 — jitter demotion

| Dimension | Value |
|-----------|-------|
| C behavior | Receiver-side, relative to mean RTT: `+5` error points when `stddev > RTT_JITTER_RATIO_HIGH (1.0) × mean`, `+10` when `> RTT_JITTER_RATIO_SEVERE (1.5) × mean`. A jittery link is down-weighted (`weight_percent` drops) but never reaped — `jitter-stress.sh` asserts 0 reaps and `disconnects == 0`. |
| Fork mechanism | Sender-side, and **not** a ported copy of the C formula. Pure jitter produces no loss, so the NAK-decay quality multiplier is unchanged and the RTT bonus (≤3 %) is marginal. The demotion is driven by the base score `window / (in_flight + 1)`: jitter delays the SRTLA-ACK return path, so in-flight stays elevated on the jittery link and its score falls, compounded by Kalman-RTT-aware EDPF arrival prediction. The link is continuously down-weighted, never hard-killed (the fork's "demote lossy links continuously, never hard-kill" stance). |
| Verified outcome | Two clean links balance at **50.3 % / 49.7 %**. After applying `netem delay 150ms 200ms distribution normal` to link 1 (jitter-stress.sh phase 3), link 1's selection share falls to **11.8 %** — a **76.6 % relative drop** (≥ 30 % required). **0** established-link reconnects/disconnects; the bonded stream continues as link 0 absorbs the shifted traffic. |
| Divergence verdict | **EQUIVALENT OUTCOME via a DIFFERENT MECHANISM.** C penalizes jitter at the receiver (a `weight_percent` input); the fork demotes the jittery link at the sender through its in-flight/RTT-aware scheduler. The observable result is identical — the jittery link gets materially less traffic and is never disconnected. The fork deliberately does **not** replicate C's stddev/mean jitter-penalty formula (that is a receiver-scoring input, not a sender scheduler input, and porting it verbatim would defeat the point of adopting the Rust scheduler). This matches the adoption posture in §3. |

### Net verdict

Both PR #19 behaviors are reproduced at the outcome level with no behavior that
would break interop with the C receiver. The only divergences are (a) the
integer-second keepalive jitter that C shares, and (b) the sender-side rather
than receiver-side locus of jitter demotion — both benign and both documented
above. No change to the default scheduling mode (`enhanced`) was required or
made.

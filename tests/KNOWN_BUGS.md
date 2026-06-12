# Known Bugs — srtla test suite

This file tracks behaviors that tests have proven incorrect but which are
intentionally left RED (named `*_KNOWNBUG`) pending a dedicated fix task.
A test only belongs here if it asserts the *correct* behavior and fails
against current production code.

## REG handshake state machine (`test_registration_handshake.cpp`)

**No known bugs.** Every REG1/REG2/REG3 transition characterized by
`test_registration_handshake.cpp` matches the shipped behavior of
`SRTLAHandler::register_group` / `register_connection`, so all tests pass
green (characterization).

Two behaviors looked surprising during analysis but are intentional and are
documented inline in the test file rather than flagged as bugs:

- **Malformed REG1 (wrong size or wrong magic) draws no reply.**
  `is_srtla_reg1()` requires an exact 258-byte frame with the `0x9200`
  magic. Anything else is not recognized as a REG1, matches no connection
  address, and is dropped silently. The receiver deliberately stays quiet
  for unrecognized input instead of emitting `REG_ERR` — replying to
  arbitrary UDP garbage would let any stray packet elicit a response.
  `REG_ERR` is reserved for *recognized* registration attempts that fail
  (max-groups reached, source address already registered, group-id
  mismatch, max-conns-per-group reached).

- **Inbound `REG_NAK` (0x9212) is ignored.** `REG_NAK` is a CeraLive-only
  type emitted by the *sender*; the receiver has no inbound handler for it.
  A 2-byte `0x9212` frame is not REG1/2/3, matches no address, and is
  shorter than `SRT_MIN_LEN`, so it is dropped without a reply or state
  change. The test freezes that "ignored, never crashes" contract.

## Hardening reproducers (Task 14)

Five scenario families were probed for races, resource exhaustion, timeout
handling, receiver restart, and concurrent registration:

| Family | Test file / scenario | Result |
|--------|----------------------|--------|
| 1. REG3/NGP race | `test_reg_race.cpp` (`RaceReg3Ngp.*`) | all green |
| 2. MAX_GROUPS exhaustion | `test_group_limits.cpp` (`GroupLimits.*`) | all green |
| 3. timeout / cleanup | `test_timeout_cleanup.cpp` (`TimeoutCleanup.*`) | all green |
| 4. receiver restart | `tests/compat/scenarios/receiver-restart.sh` | PASS |
| 5. concurrent multi-interface | `test_reg_race.cpp` (`ConcurrentMultiInterface.*`) | all green |

**No crashes and no defects found.** The REG3/NGP race fix from the upstream
v2.2.0+ lineage is present in the merged code (`aa66a88` lineage): concurrent,
randomized-interleaving REG2 from three links over >=500 iterations always
yields exactly one group with three connections, every link REG3'd, and zero
REG_NGP storms; a REG2 ahead of its group draws exactly one REG_NGP (the retry
trigger), never a storm; a repeated REG2 from a registered link is idempotent.
The receiver-restart scenario shows OUR `srtla_send` re-registers within ~5 s
and resumes media (~1.5 MB to a fresh sink) after a `SIGKILL`+restart — where
the BELABOX baseline did not re-register inside 30 s
(`tests/compat/SMOKE_BASELINE.md` Phase B). So every Task-14 test is a
regression pin (GREEN), not a RED `*_KNOWNBUG`.

### Hardening observation for Task 15 (not a bug)

`register_group()` creates one group per accepted REG1 and does **not** dedupe
by client id. A sender that mints many *distinct* REG1s (different source
addresses, even with the same id first-half) therefore consumes one
`MAX_GROUPS` slot each, and can reach the cap.
`ConcurrentMultiInterface.DuplicateReg1SameIdHalf_CreatesDistinctGroups` pins
this current behavior. It is **not** a crash or a correctness bug — at the cap
the next REG1 is cleanly rejected with `REG_ERR`
(`GroupLimits.AtMaxGroups_Reg1GetsRegErr`) and `GROUP_TIMEOUT` reaps idle
groups — and a well-behaved sender only emits REG1 from link 0. It is recorded
here as a denial-of-service hardening lever (e.g. id-based group dedupe or a
per-source REG1 rate limit). Changing it would flip the
`DuplicateReg1SameIdHalf_CreatesDistinctGroups` expectation, so update that pin
together with any fix.

**Task 15 outcome.** Task 15 reviewed this worklist and found **no
`*_KNOWNBUG` test** — every reproducer is green, so no production behavior was
changed (the rule is: no fix without a driving RED test). In particular the
id-dedupe lever above was left as-is; bounding it needs its own task that flips
the pin under test. Task 15 instead added per-group structured lifecycle events
to `srtla_rec` (`group_registered`, `conn_added`, `conn_removed reason=…`,
`group_reaped reason=…`, alongside the existing `quality_path=…`) for
operator-visible register→stream→timeout→reap tracing. See
`docs/TROUBLESHOOTING.md` → *Structured Lifecycle Events*.

## Sender link management (Task 17)

Sender-side bootstrap, recovery, and SIGHUP reload are now under test. **No RED
`*_KNOWNBUG`** — every item is a green regression pin or a fix shipped with a
driving test (no fix without a test).

- **Bootstrap registration (906ac05 regression pin).** `conn_is_timed_out()` and
  `housekeeping_action()` were extracted into `src/sender_logic.h` so the
  fresh-link bootstrap decision is testable without sockets/globals.
  `test_sender_bootstrap.cpp` pins it: a never-received link (`last_rcvd == 0`)
  is **not** timed out and takes the `BootstrapRegister` path on the first
  housekeeping tick. Reverting either half of 906ac05 turns these two tests red
  (verified by temporarily reverting the guard).

- **SIGHUP reload guard (fix + driving test).** `update_conns()` previously tore
  down every connection when a SIGHUP reload resolved to zero valid source IPs
  (empty/garbage file), and `setup_conns()` would `exit()` on an unreadable file
  — so a bad reload killed the stream or crashed the sender. It now counts
  parseable IPs first (`count_parseable_source_ips`/`reload_should_apply`) and
  refuses a zero-valid-IP reload, logging a parse error and keeping the existing
  links. Driven by `test_sender_bootstrap.cpp` (unit) and the
  `sighup-reload.sh` invalid-reload phase (end-to-end).

- **Receiver-matched silence timeout (sender false-down fix).**
  `SENDER_CONN_TIMEOUT` was 4 s — 3.75x tighter than the receiver's
  `CONN_TIMEOUT` (15 s). For any inbound gap in (4 s, 15 s) the receiver still
  held the link and kept echoing keepalives while the sender declared it dead
  and forced a re-register + window reset to `WINDOW_MIN` — the "server in
  another country" false link-down on a jittery-but-alive high-RTT uplink. It is
  now aligned to the receiver's 15 s window in `src/sender_logic.h`, so the two
  ends agree on liveness. Dead-link detection latency is **not** sacrificed: a
  hard send failure disables a link immediately via the timeout-independent
  sendto-failure path in `handle_srt_data()`, so real link-drops still shift in
  <1 s (`link-drop.sh` ~457 ms, `link-drop-high-rtt.sh` ~888 ms — both via that
  path, not the passive timeout). Driven by `test_timeout_boundaries.cpp`:
  `SenderFalselyDownsAliveLinkOnSubReceiverTimeoutGap` flips red→green while
  `SenderDeadLinkDetectedWithinFourToFiveSeconds` stays green.

### New harness scenarios (`tests/compat/scenarios/`)

| Scenario | Proves |
|----------|--------|
| `link-drop.sh` | Two bonded loopback links; isolating one with iptables makes the sender shift off it within `CONN_TIMEOUT` (survivor stays up) and re-register it on restore. SKIPs cleanly without iptables/sudo. |
| `sighup-reload.sh` | Appending a source IP + SIGHUP joins the new link to the existing group with 0 disconnects (no re-handshake); a garbage file + SIGHUP is refused without crashing or dropping links. |
| `jitter-stress.sh` | Two bonded links under three escalating live `netem` jitter phases (`150ms ±50/100/200ms`, no loss) keep streaming with strictly-increasing per-phase throughput, ZERO receiver link reaps, both links registered, and `disconnects == 0` — proving jitter alone never reaps a healthy link (stresses `RTT_VARIANCE_THRESHOLD=50ms`). SKIPs cleanly (exit 77) without `CAP_NET_ADMIN`+`ip`/`tc`/`ping`. |

> The `link-drop.sh` verdict gates on the **sender's** deterministic behavior
> (shift + survivor-up + recovery + media delivered). End-to-end SRT
> `disconnects` is recorded but **not** a pass gate: riding a hard mid-stream
> dual-direction link kill without an SRT break is an SRT app-layer property
> (the caller's send window stalls on the in-flight packets lost with the link,
> against ffmpeg's fixed ~5 s peer-idle timeout), orthogonal to bonding
> correctness. `sighup-reload.sh` and `jitter-stress.sh` kill no link, so they
> **do** assert `disconnects == 0` (jitter-stress delivers every packet, just
> late — the multi-second SRT window must ride it through).

## Sender telemetry (Task 18)

Telemetry emission via `--stats-file` is now under test. **No RED `*_KNOWNBUG`** — all items are green regression pins or fixes shipped with driving tests.

- **Stats file emission (156826d).** `srtla_send` writes a per-uplink JSON snapshot to the path given by `--stats-file` every 1000 ms via atomic `rename(2)`. `test_telemetry_emit.cpp` pins: file appears within the write interval; JSON parses against the ADR-001 schema; `"connections": []` is written when no links are active; a concurrent reader in a tight loop never observes a torn document; the file is removed on clean shutdown. The 63-test ctest suite stays green with telemetry enabled.

- **Opt-in only.** When `--stats-file` is not passed, no file or temp sibling is ever opened. The flag is absent from the CeraUI spawn path until Task 19 wires it up; the sender is safe to run without it.

- **Schema contract fixed by ADR-001.** The JSON field names, types, units, and staleness threshold (`SENDER_TELEMETRY_STALE_MS = 5000`) are defined in `docs/adr/ADR-001-telemetry-ipc.md` and implemented in `src/sender_telemetry.h`. Drift between the C producer and the TS consumer (Tasks 19/21/22) is a release blocker — the canonical example in the ADR must parse via the additive Zod schema.

**Open hardening lever (not a bug).** The `weight_percent` field is always reported as `SENDER_DEFAULT_WEIGHT_PERCENT` (100) because `srtla_send` does not run the receiver's load-balancer scoring. Reporting a real per-link weight would require porting the scoring algorithm into the sender, which is out of scope for Task 18. The field is present and correct per the ADR contract; a future task can populate it from actual sender-side scoring if needed. No `*_KNOWNBUG` test exists for this — it is a known limitation, not a defect.

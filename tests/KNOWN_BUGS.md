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

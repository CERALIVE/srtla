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

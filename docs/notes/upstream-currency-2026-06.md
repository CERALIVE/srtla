# srtla upstream currency report — June 2026

**Date:** 2026-06-23
**Branch:** `merge/upstream-2026-06`
**Merge commit:** `edc04d6`

---

## What changed

This merge advances the fork's merge-base with `irlserver/srtla` from `2de6dbb` to
`39e324a`. That's the primary outcome: lineage is now clean. `irlserver/main` is a
true ancestor of our HEAD, so future catch-ups start from the right base.

No new features were added by this merge. Both upstream commits (`7855012` and
`39e324a`) were already present in our tree as prior cherry-picks. The merge
resolved to ours on every conflict file because our fork is a strict superset of
upstream's changes.

### Upstream commits absorbed

| SHA | Subject |
|-----|---------|
| `7855012` | fix(receiver): prevent pre-auth group table exhaustion dos |
| `39e324a` | feat(receiver): throttle source ips that repeatedly fail srt auth |

Both commits were already carried in our tree. The equivalence was verified by
examining each upstream commit's additions and confirming the same content exists
in our HEAD:

- `7855012` (ghost-group eviction): `PENDING_GROUP_TIMEOUT`, `evict_oldest_pending_group()`,
  `mark_data_seen()` / `has_seen_data()` all present in `src/connection/`. Our version
  additionally wires `mark_data_seen()` into `SRTLAHandler::process_single_packet` and
  adds the ghost-eviction GTest suite.
- `39e324a` (per-IP auth-fail rate limiter): `AUTH_FAIL_THRESHOLD=5`,
  `AUTH_FAIL_WINDOW=60`, `AUTH_FAIL_COOLDOWN=60` present in `src/receiver_config.h`;
  `class AuthRateLimiter` present in `src/utils/auth_rate_limiter.{h,cpp}` with
  identical public API and IP-only keying. Our version additionally adds the
  `AuthRateLimiter` GTest suite.

### Merge execution

The merge used `git merge --no-ff --no-commit irlserver/main` (not `-s ours`).
Eleven content conflicts were resolved to ours after per-file verification; two
files auto-merged byte-identical to our HEAD. No conflict markers remain. The
`irlserver` remote was added transiently inside the merge worktree and removed
before any push, per the transient-remote recipe in `scripts/upstream-merge.sh`.

---

## Validation

### ctest (unit + integration)

```
cmake -B build && cmake --build build -j
(cd build && ctest --output-on-failure)
```

Result: **186/186 passed, 0 failed** (exit 0).

All 19 GTest suites green, including `test_ghost_group_eviction.cpp` and the
`AuthRateLimiter` suite that pin the two upstream commits.

### Compat blocking tier

```
cmake -B build -DBUILD_COMPAT_TESTS=ON && cmake --build build -j
tests/compat/run-matrix.sh --tier blocking
```

Result: **9/9 PASS, 0 FAIL, 0 SKIP** (harness exit 0). All three
`ceralive-srtla-send-rs` (Rust fork) pairs passed; none skipped.

Per-pair summary:

| Pair | bytes | first_byte_ms | disconnects |
|------|------:|-------------:|------------:|
| belabox-senderxours | 3 052 368 | 2 633 | 0 |
| irlserver-sendxours | 2 927 724 | 3 496 | 0 |
| ceralive-send-rsxours | 2 659 260 | 3 115 | 0 |
| ceralive-send-rsxbelabox-receiver | 2 676 556 | 5 427 | 0 |
| ceralive-send-rsxopenirl-receiver | 2 676 556 | 5 404 | 0 |
| moblin-mockxours | 3 210 288 | 1 512 | 0 |
| oursxbelabox-receiver | 2 890 312 | 3 828 | 0 |
| oursxopenirl-receiver | 2 886 740 | 3 872 | 0 |
| oursxours | 2 865 308 | 1 543 | 0 |

Falsifiability confirmed: `--scenario port-mismatch` produced FAIL as expected
(`handshake_ok=false`, `bytes=0`).

---

## Merge-base proof

```
git merge-base HEAD 39e324a
# → 39e324a9420763720b9f16c463971ababa757bc1
```

`39e324a` is now a true ancestor of HEAD. The previous merge-base was `2de6dbb`.

---

## What this merge does NOT do

- No new protocol features.
- No behavioral delta: the hardening (ghost-group eviction, auth-fail rate limiter,
  RTT/jitter retune, keepalive cadence fix) was already present before this merge.
- No TS bindings changes.
- No packaging changes.

The value is purely lineage: future upstream catch-ups will start from `39e324a`
rather than `2de6dbb`, so the next sync will only need to absorb commits after
`39e324a`.

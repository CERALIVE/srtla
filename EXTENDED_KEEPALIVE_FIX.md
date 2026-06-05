# Extended Keepalive Feedback Loop Fix (historical)

> **Status: superseded.** The root cause of this bug — SRTLA ACK
> throttling — was removed by upstream commit `a89aa74`
> ("fix(receiver): remove SRTLA ACK throttling") and that removal was
> taken into the CeraLive fork. The feedback loop described below
> can no longer occur because there is no longer any time-based
> ACK gate.
>
> What we kept from the original mitigation:
> - **Lighter bandwidth penalties for senders with extended keepalive
>   telemetry** (still present in `src/quality/quality_evaluator.cpp`).
> - The persistent `supports_extended_keepalives` capability flag on
>   `ConnectionStats`.
>
> What was removed by the merge:
> - The recovery-boost block in `LoadBalancer::adjust_weights` (it
>   only existed to break the ACK-throttling feedback loop).
> - All ACK-throttle constants (`ACK_THROTTLE_INTERVAL`,
>   `MIN_ACK_RATE`) and stats fields (`ack_throttle_factor`,
>   `last_ack_sent_time`, `legacy_ack_throttle_factor`).
>
> This file is retained as a record of the original analysis. The
> body below describes behavior that no longer exists in production.

---

## Original problem (no longer reproducible)

When using `srtla_send` with extended keepalives (38-byte keepalives
with `connection_info_t`), one connection would drop to 0 bandwidth
and never recover, while the other connection carried 100% of the
traffic. This did **not** occur with vanilla `srtla_send` (minimal
2-byte keepalives).

### The feedback loop (historical)

1. **Initial state**: Both connections share traffic load.
2. **Minor network event**: One connection experiences slight
   degradation (e.g. packet loss).
3. **Client reduces usage**: Sender uses the degraded connection less.
4. **Connection becomes idle**: Idle connections send extended
   keepalives (by design).
5. **Receiver measures 0 bandwidth**: Since the connection is idle,
   receiver-side bandwidth measurement = 0.
6. **Heavy bandwidth penalty**: Receiver applied 40 error points for
   `performance_ratio < 0.3`.
7. **ACK throttling**: 40+ error points -> `WEIGHT_CRITICAL` -> 20%
   ACK throttle.
8. **Client further reduces usage**: Fewer ACKs -> lower window growth
   -> connection scored poorly.
9. **Permanent 0 bandwidth**: Connection locked at 0, never recovers.

Step 7 is gone, so the loop cannot close.

## What still applies

### Lighter bandwidth penalties for telemetry-aware senders

**File**: `src/quality/quality_evaluator.cpp`

For connections WITH sender telemetry (extended keepalives):
- Bandwidth penalty for `performance_ratio < 0.3` is reduced from 40
  to 10 points; other tiers reduced proportionally.
- Quality leans on telemetry metrics (RTT, NAK rate, window
  utilization) as primary indicators.

For connections WITHOUT telemetry (legacy senders):
- Original aggressive penalties (40 points for < 0.3) preserved.
- Bandwidth remains the primary quality indicator.

This still helps mixed-sender environments differentiate between
"actually bad link" and "idle but healthy link".

## Bandwidth penalty comparison (current)

| Performance ratio | Legacy senders | With telemetry |
|-------------------|----------------|----------------|
| < 0.3             | 40 points      | 10 points      |
| 0.3 - 0.5         | 25 points      | 7 points       |
| 0.5 - 0.7         | 15 points      | 4 points       |
| 0.7 - 0.85        | 5 points       | 2 points       |

## Backward compatibility

- Legacy senders: unchanged.
- Extended-keepalive senders: original feedback loop is impossible
  (ACK throttling removed); lighter penalties still apply.
- No protocol changes.
- No configuration changes needed.

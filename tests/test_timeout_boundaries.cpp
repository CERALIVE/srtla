/*
    srtla - SRT transport proxy with link aggregation
    Copyright (C) 2026 CeraLive

    Timeout boundary contracts for the receiver reaper and the sender link
    watchdog under HIGH-RTT / JITTER conditions — the "server in another
    country" failure mode where ~500ms RTT plus jitter must never cause a false
    link-down.

    ── No real sleeps ────────────────────────────────────────────────────────
    The receiver path is driven through
    ConnectionRegistry::cleanup_inactive(time_t, keepalive_cb) — the same
    injected-clock seam test_timeout_cleanup.cpp uses. The reaper keeps a
    process-static `last_run`, so every test takes a fresh, far-apart logical
    base (fresh_base, atomic) and the first cleanup of each case is never
    throttled regardless of execution order (--gtest_shuffle safe).

    The sender path is driven through the pure predicate
    srtla::sender::conn_is_timed_out(last_rcvd, now), which sender.cpp routes
    every link decision through (conn_timed_out() / housekeeping_action()).
    Both seams take whole-second time_t values exactly as the shipped code does
    (the reaper takes a time_t parameter; the sender derives last_rcvd /
    `time` from get_seconds() / get_ms()/1000). Minutes of protocol time are
    simulated in microseconds of wall time.

    ── RED / GREEN inventory ────────────────────────────────────────────────
      (a)  ReceiverConnTimeoutBoundaryExact ............... GREEN  boundary
      (a2) SenderConnTimeoutBoundaryExact ................. GREEN  boundary
      (b)  ReceiverKeepaliveJitterNeverReaps .............. GREEN  60s jitter
      (c)  ReceiverRecoveryWindowStarvedByCleanupThrottle . RED    Task 15
      (d0) SenderBenignHighRttJitterStaysUp ............... GREEN  30s jitter
      (d)  SenderFalselyDownsAliveLinkOnSubReceiverGap .... RED    Task 14
      (e)  SenderDeadLinkDetectedWithinFourToFiveSeconds .. GREEN  dead-link

    RED cases assert the *intended* contract and fail against shipped behavior,
    documenting the defect inline (see each `// RED:` marker). GREEN cases pin
    behavior that already holds and that the Task 14/15 fixes must preserve. In
    particular (e) bounds dead-link detection to ≤5s, so a fix for (d) that
    merely *widens* SENDER_CONN_TIMEOUT (instead of distinguishing jittery-alive
    from genuinely dead) would correctly turn (e) red — both sides of the
    contract are encoded now.
*/

#include <gtest/gtest.h>

#include <netinet/in.h>
#include <sys/socket.h>

#include <array>
#include <atomic>
#include <cstddef>
#include <cstring>
#include <functional>
#include <memory>

#include "connection/connection.h"
#include "connection/connection_group.h"
#include "connection/connection_registry.h"
#include "receiver_config.h"
#include "sender_logic.h"

using srtla::CLEANUP_PERIOD;
using srtla::CONN_TIMEOUT;
using srtla::KEEPALIVE_PERIOD;
using srtla::RECOVERY_CHANCE_PERIOD;
using srtla::connection::Connection;
using srtla::connection::ConnectionGroup;
using srtla::connection::ConnectionGroupPtr;
using srtla::connection::ConnectionPtr;
using srtla::connection::ConnectionRegistry;
using srtla::sender::conn_is_timed_out;
using srtla::sender::SENDER_CONN_TIMEOUT;

namespace {

// Strictly-increasing, far-apart time base per test. cleanup_inactive keeps a
// static `last_run`, so every test must start above the previous test's last
// seen timestamp; the atomic fetch_add holds in any execution order, so the
// first cleanup of each case is never throttled (shuffle-safe).
time_t fresh_base() {
    static std::atomic<time_t> base{2'000'000};
    return base.fetch_add(1'000'000);
}

struct sockaddr_storage make_addr(uint16_t port) {
    struct sockaddr_storage ss;
    std::memset(&ss, 0, sizeof(ss));
    auto *in = reinterpret_cast<struct sockaddr_in *>(&ss);
    in->sin_family = AF_INET;
    in->sin_port = htons(port);
    in->sin_addr.s_addr = htonl(0x7f000001);
    return ss;
}

ConnectionPtr make_conn(uint16_t port, time_t last_received) {
    return std::make_shared<Connection>(make_addr(port), last_received);
}

ConnectionGroupPtr make_group(time_t created_at) {
    std::array<char, SRTLA_ID_LEN> id{};
    std::memcpy(id.data(), "timeout-boundary-group", 22);
    return std::make_shared<ConnectionGroup>(id.data(), created_at);
}

} // namespace

// ===========================================================================
// (a) Receiver connection-timeout boundary exactness — GREEN.
//
// The reaper compares whole seconds (time_t). The documented 14.9s→alive /
// 15.1s→reaped intent maps onto the strict "<" CONN_TIMEOUT boundary:
//   ts - last_received <= CONN_TIMEOUT (15) -> retained
//   ts - last_received  > CONN_TIMEOUT (15) -> reaped
// i.e. no premature reap at or before 15s, reap strictly after.
// ===========================================================================
TEST(TimeoutBoundaries, ReceiverConnTimeoutBoundaryExact) {
    auto silence_leaves_conns = [](time_t silence) -> std::size_t {
        time_t t0 = fresh_base();
        ConnectionRegistry reg;
        auto group = make_group(t0);
        group->add_connection(make_conn(50001, t0));
        reg.add_group(group);
        reg.cleanup_inactive(t0 + silence, nullptr);
        // The now-empty group is not itself reaped here (created_at + 30 not yet
        // crossed), so groups() stays size 1 and we read its connection count.
        return reg.groups().empty() ? 0u : reg.groups()[0]->connections().size();
    };

    EXPECT_EQ(silence_leaves_conns(CONN_TIMEOUT - 1), 1u) << "14s silent: alive";
    EXPECT_EQ(silence_leaves_conns(CONN_TIMEOUT), 1u)
        << "exactly 15s silent: alive (strict \"<\" boundary)";
    EXPECT_EQ(silence_leaves_conns(CONN_TIMEOUT + 1), 0u) << "16s silent: reaped";
}

// ===========================================================================
// (a2) Sender connection-timeout boundary exactness — GREEN.
//
// Mirror of (a) on the sender side: conn_is_timed_out is strict "<" at exactly
// SENDER_CONN_TIMEOUT, and a never-received link (last_rcvd == 0) is
// not-yet-established rather than timed out (906ac05 guard, also pinned by
// test_sender_bootstrap — repeated here so the boundary story is self-contained).
// ===========================================================================
TEST(TimeoutBoundaries, SenderConnTimeoutBoundaryExact) {
    const time_t t = 1'000; // monotonic seconds, well past SENDER_CONN_TIMEOUT
    EXPECT_FALSE(conn_is_timed_out(t, t + SENDER_CONN_TIMEOUT - 1)) << "3s: alive";
    EXPECT_FALSE(conn_is_timed_out(t, t + SENDER_CONN_TIMEOUT))
        << "exactly 4s: alive (strict \"<\" boundary)";
    EXPECT_TRUE(conn_is_timed_out(t, t + SENDER_CONN_TIMEOUT + 1)) << "5s: timed out";
    EXPECT_FALSE(conn_is_timed_out(0, t)) << "never received: not-yet-established";
}

// ===========================================================================
// (b) Receiver keepalive jitter never reaps over 60s — GREEN.
//
// Keepalives on a KEEPALIVE_PERIOD(1s) cadence reaching a far receiver with
// ~500ms one-way latency and jitter land with 1–2s inter-arrival. The receiver
// bumps last_received on every inbound packet, so jitter does NOT accumulate —
// each arrival resets the clock. The worst-case staleness the reaper ever sees
// is one missed cadence (~2s), far below CONN_TIMEOUT(15s). This case is GREEN
// by construction: jitter provably cannot cross the 15s timeout, so it is NOT
// marked RED (contrast the 4s sender budget in (d), where it can).
// ===========================================================================
TEST(TimeoutBoundaries, ReceiverKeepaliveJitterNeverReapsOverSixtySeconds) {
    time_t t0 = fresh_base();
    ConnectionRegistry reg;
    auto group = make_group(t0);
    auto conn = make_conn(50001, t0);
    group->add_connection(conn);
    reg.add_group(group);

    time_t next_arrival = t0;
    int gap = 2; // alternate 2s/1s inter-arrival: sub-second jitter that pushes
                 // some arrivals into the next integer second, max gap 2s.
    for (time_t s = 0; s <= 60; ++s) {
        const time_t now = t0 + s;
        if (now >= next_arrival) {
            conn->update_last_received(now); // keepalive echo landed this second
            next_arrival = now + gap;
            gap = (gap == 2) ? 1 : 2;
        }
        reg.cleanup_inactive(now, nullptr);

        ASSERT_EQ(reg.groups().size(), 1u) << "group reaped at +" << s << "s";
        ASSERT_EQ(reg.groups()[0]->connections().size(), 1u)
            << "connection falsely reaped at +" << s << "s (jitter ≤2s ≪ 15s)";
    }
}

// ===========================================================================
// (c) Receiver recovery window starved by the cleanup throttle — RED (Task 15).
//
// A link entering recovery should get a full RECOVERY_CHANCE_PERIOD(5s) of
// usable probe attempts at KEEPALIVE_PERIOD(1s) cadence — with 500ms-RTT
// responses that is time for ~5 round trips, ~5 attempts. The recovery
// keepalive callback, however, is fired ONLY from cleanup_inactive(), which
// self-throttles to once per CLEANUP_PERIOD(3s). So in a 5s window the callback
// fires only at t0 and t0+3 — 2 of the intended ~5 attempts.
// ===========================================================================
TEST(TimeoutBoundaries, ReceiverRecoveryWindowStarvedByCleanupThrottle) {
    time_t t0 = fresh_base();
    ConnectionRegistry reg;
    auto group = make_group(t0);
    // In recovery at t0; last traffic 2s ago (idle past KEEPALIVE_PERIOD, far
    // inside CONN_TIMEOUT) and no renewed traffic during the window.
    auto conn = make_conn(50001, t0 - 2);
    conn->set_recovery_start(t0);
    group->add_connection(conn);
    reg.add_group(group);

    int recovery_keepalives = 0;
    auto cb = [&](ConnectionPtr, time_t) { ++recovery_keepalives; };

    // The receiver main loop calls cleanup_inactive on every iteration; poll it
    // once per simulated second across the whole RECOVERY_CHANCE_PERIOD. Calling
    // it more often does not help — the throttle gates the body to every 3s.
    for (time_t s = 0; s <= RECOVERY_CHANCE_PERIOD; ++s) {
        reg.cleanup_inactive(t0 + s, cb);
    }

    ASSERT_EQ(reg.groups()[0]->connections().size(), 1u)
        << "recovering link stays well within CONN_TIMEOUT for the whole window";

    const int intended_attempts = RECOVERY_CHANCE_PERIOD / KEEPALIVE_PERIOD; // 5

    // RED: documents defect — the recovery keepalive callback is driven only by
    // cleanup_inactive(), which self-throttles to CLEANUP_PERIOD(3s), so the
    // recovery probe cadence is 3s rather than KEEPALIVE_PERIOD(1s); a 5s
    // RECOVERY_CHANCE_PERIOD window delivers ~2 of the intended ~5 usable
    // attempts, shrinking the effective recovery window; fix tracked in plan Task 15 (receiver)
    EXPECT_GE(recovery_keepalives, intended_attempts - 1)
        << "recovery window delivered " << recovery_keepalives
        << " keepalive attempts; intended ≈" << intended_attempts
        << " (one per KEEPALIVE_PERIOD across RECOVERY_CHANCE_PERIOD)";
}

// ===========================================================================
// (d0) Sender benign high-RTT jitter stays up — GREEN.
//
// 500ms RTT, ±200ms jitter, ~1s keepalive/ACK cadence: inbound feedback lands
// every ~0.8–1.4s, so truncated-to-seconds inter-arrival never exceeds 2s.
// Sustained 30s. The 4s watchdog has comfortable margin over benign jitter —
// only the >4s stalls exercised by (d) are the problem. Positive contract the
// Task 14 fix must keep holding.
// ===========================================================================
TEST(TimeoutBoundaries, SenderBenignHighRttJitterStaysUp) {
    const time_t start = 1'000;
    time_t last_rcvd = start;
    time_t next_arrival = start;
    int gap = 2;
    bool ever_down = false;

    for (time_t now = start; now <= start + 30; ++now) {
        if (now >= next_arrival) {
            last_rcvd = now; // feedback echo landed this second
            next_arrival = now + gap;
            gap = (gap == 2) ? 1 : 2;
        }
        if (conn_is_timed_out(last_rcvd, now)) {
            ever_down = true;
        }
    }

    EXPECT_FALSE(ever_down)
        << "benign 500ms-RTT jitter (≤2s inter-arrival) must never trip the 4s watchdog";
}

// ===========================================================================
// (d) Sender falsely downs an alive link on a sub-receiver-timeout gap — RED
//     (Task 14).
//
// A 500ms-RTT cellular uplink routinely sees multi-second inbound feedback gaps
// (consecutive keepalive-echo loss, a brief radio stall / handover) while
// staying associated and alive. The receiver treats any silence below
// CONN_TIMEOUT(15s) as alive and echoes keepalives; the two ends must agree on
// liveness. For every gap strictly between the sender's 4s budget and the
// receiver's 15s budget, the receiver keeps the link but the sender declares it
// dead — forcing a needless re-register and window reset to WINDOW_MIN.
// ===========================================================================
TEST(TimeoutBoundaries, SenderFalselyDownsAliveLinkOnSubReceiverTimeoutGap) {
    const time_t last_feedback = 1'000; // link was alive

    for (time_t silence = SENDER_CONN_TIMEOUT + 1; silence < CONN_TIMEOUT; ++silence) {
        const time_t now = last_feedback + silence;

        // The receiver's 15s standard still considers this link alive.
        const bool receiver_keeps_alive = !((last_feedback + CONN_TIMEOUT) < now);
        ASSERT_TRUE(receiver_keeps_alive)
            << "scenario guard: " << silence << "s silence is below CONN_TIMEOUT(15s)";

        // RED: documents defect — SENDER_CONN_TIMEOUT(4s) is 3.75x tighter than
        // the receiver's CONN_TIMEOUT(15s), so a sub-15s inbound gap on an alive
        // 500ms-RTT link is declared timed out by the sender (false link-down:
        // re-register + window reset to WINDOW_MIN) while the receiver and the
        // physical link are fine; the single-last_rcvd predicate cannot tell
        // jittery-alive from dead; fix tracked in plan Task 14 (sender)
        EXPECT_FALSE(conn_is_timed_out(last_feedback, now))
            << "sender falsely downs an alive link after " << silence
            << "s of inbound silence (receiver still holds it)";
    }
}

// ===========================================================================
// (e) Sender dead-link detection within 4–5s — GREEN.
//
// A genuinely dead link (alive once, then silent forever) must still be caught
// quickly. Strict "<" keeps it alive at exactly SENDER_CONN_TIMEOUT and detects
// it one second later, so detection lands inside 4–5s. This guards the OTHER
// side of (d): a Task 14 fix that simply widens SENDER_CONN_TIMEOUT past 5s
// would push dead-link detection out of this window and turn this GREEN guard
// red — the fix must distinguish jittery-alive from dead, not merely lengthen
// the silence budget.
// ===========================================================================
TEST(TimeoutBoundaries, SenderDeadLinkDetectedWithinFourToFiveSeconds) {
    const time_t last_rcvd = 1'000; // alive once, then goes silent forever

    EXPECT_FALSE(conn_is_timed_out(last_rcvd, last_rcvd + SENDER_CONN_TIMEOUT))
        << "exactly 4s: still alive (strict \"<\")";
    EXPECT_TRUE(conn_is_timed_out(last_rcvd, last_rcvd + SENDER_CONN_TIMEOUT + 1))
        << "5s: dead link detected";

    // Detection must stay inside 4–5s for any silence beyond the budget.
    for (time_t silence = SENDER_CONN_TIMEOUT + 1; silence <= 5; ++silence) {
        EXPECT_TRUE(conn_is_timed_out(last_rcvd, last_rcvd + silence))
            << "a truly dead link must be detected within ~5s (silence " << silence << "s)";
    }
}

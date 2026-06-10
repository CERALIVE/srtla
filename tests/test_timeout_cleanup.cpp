/*
    srtla - SRT transport proxy with link aggregation
    Copyright (C) 2026 CeraLive

    Hardening reproducers — Family 3 (timeout / cleanup).

    ConnectionRegistry::cleanup_inactive(time_t ts, keepalive_cb) takes the
    current time as a parameter, so the whole reaper is driven from an injected
    logical clock — no 15s/30s wall-clock sleeps, fully deterministic.

    Pinned behavior (src/connection/connection_registry.cpp:89-164,
    src/receiver_config.h):
      * a connection silent > CONN_TIMEOUT (15s) is removed; at exactly 15s it
        is retained (the boundary is strict "<");
      * a group with no connections, idle > GROUP_TIMEOUT (30s) since creation,
        is reaped; an active connection keeps it alive;
      * the recovery-mode keepalive callback fires for a connection idle past
        KEEPALIVE_PERIOD (1s) but still inside CONN_TIMEOUT;
      * connection recovery state clears on renewed traffic (completed) or after
        RECOVERY_CHANCE_PERIOD without it (failed);
      * cleanup_inactive self-throttles to once per CLEANUP_PERIOD (3s).

    The reaper keeps a process-static `last_run`, so each test takes a fresh,
    strictly-increasing time base (fresh_base, atomic) far beyond any prior
    base. That guarantees the first cleanup call in every test clears the
    throttle regardless of test execution order (including --gtest_shuffle).

    These are current-behavior pins (the reaper works) — the regression net for
    Task 15, not RED tests.
*/

#include <gtest/gtest.h>

#include <netinet/in.h>
#include <sys/socket.h>

#include <array>
#include <atomic>
#include <cstring>
#include <memory>
#include <vector>

#include "connection/connection.h"
#include "connection/connection_group.h"
#include "connection/connection_registry.h"
#include "receiver_config.h"

using srtla::CLEANUP_PERIOD;
using srtla::CONN_TIMEOUT;
using srtla::GROUP_TIMEOUT;
using srtla::KEEPALIVE_PERIOD;
using srtla::RECOVERY_CHANCE_PERIOD;
using srtla::connection::Connection;
using srtla::connection::ConnectionGroup;
using srtla::connection::ConnectionGroupPtr;
using srtla::connection::ConnectionPtr;
using srtla::connection::ConnectionRegistry;

namespace {

// Strictly-increasing, far-apart time base per test. Because cleanup_inactive
// keeps a static `last_run`, every test must start above the previous test's
// last seen timestamp; an atomic fetch_add makes that hold in execution order,
// so the first cleanup of each test is never throttled (shuffle-safe).
time_t fresh_base() {
    static std::atomic<time_t> base{1'000'000};
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
    std::memcpy(id.data(), "timeout-cleanup-group", 21);
    return std::make_shared<ConnectionGroup>(id.data(), created_at);
}

} // namespace

// A connection silent for more than CONN_TIMEOUT is reaped.
TEST(TimeoutCleanup, ConnectionSilentBeyondTimeout_Removed) {
    time_t t0 = fresh_base();
    ConnectionRegistry reg;
    auto group = make_group(t0);
    group->add_connection(make_conn(50001, t0));
    reg.add_group(group);

    // 16s of silence: last_received + CONN_TIMEOUT(15) < ts.
    reg.cleanup_inactive(t0 + CONN_TIMEOUT + 1, nullptr);

    ASSERT_EQ(reg.groups().size(), 1u) << "group not yet old enough to reap";
    EXPECT_EQ(reg.groups()[0]->connections().size(), 0u);
}

// At exactly CONN_TIMEOUT the connection is still alive (strict "<" boundary).
TEST(TimeoutCleanup, ConnectionAtTimeoutBoundary_Retained) {
    time_t t0 = fresh_base();
    ConnectionRegistry reg;
    auto group = make_group(t0);
    group->add_connection(make_conn(50001, t0));
    reg.add_group(group);

    reg.cleanup_inactive(t0 + CONN_TIMEOUT, nullptr); // exactly 15s

    ASSERT_EQ(reg.groups().size(), 1u);
    EXPECT_EQ(reg.groups()[0]->connections().size(), 1u);
}

// An empty group idle past GROUP_TIMEOUT is reaped. At t0+31 the lone
// connection times out and, in the same pass, the now-empty group is removed.
TEST(TimeoutCleanup, GroupSilentBeyondTimeout_Reaped) {
    time_t t0 = fresh_base();
    ConnectionRegistry reg;
    auto group = make_group(t0);
    group->add_connection(make_conn(50001, t0));
    reg.add_group(group);

    reg.cleanup_inactive(t0 + GROUP_TIMEOUT + 1, nullptr); // 31s

    EXPECT_EQ(reg.groups().size(), 0u);
}

// A group with an active connection is never reaped, even past GROUP_TIMEOUT.
TEST(TimeoutCleanup, GroupWithActiveConnection_NotReaped) {
    time_t t0 = fresh_base();
    ConnectionRegistry reg;
    auto group = make_group(t0);
    // Fresh traffic at t0+30 keeps the connection (and thus the group) alive.
    group->add_connection(make_conn(50001, t0 + GROUP_TIMEOUT));
    reg.add_group(group);

    reg.cleanup_inactive(t0 + GROUP_TIMEOUT + 1, nullptr);

    ASSERT_EQ(reg.groups().size(), 1u);
    EXPECT_EQ(reg.groups()[0]->connections().size(), 1u);
}

// The recovery keepalive callback fires for a connection idle past
// KEEPALIVE_PERIOD but still within CONN_TIMEOUT.
TEST(TimeoutCleanup, RecoveryKeepaliveCallbackFiresWithinWindow) {
    time_t t0 = fresh_base();
    ConnectionRegistry reg;
    auto group = make_group(t0);
    auto conn = make_conn(50001, t0);
    group->add_connection(conn);
    reg.add_group(group);

    std::vector<ConnectionPtr> fired;
    // ts = t0+2: not timed out (2 < 15) but last_received + KEEPALIVE_PERIOD(1) < ts.
    reg.cleanup_inactive(t0 + 2, [&](ConnectionPtr c, time_t) { fired.push_back(c); });

    ASSERT_EQ(fired.size(), 1u) << "keepalive callback should fire once for the idle connection";
    EXPECT_EQ(fired[0], conn);
    EXPECT_EQ(reg.groups()[0]->connections().size(), 1u) << "callback must not remove the connection";
}

// A recovering connection that receives traffic after recovery_start, observed
// past RECOVERY_CHANCE_PERIOD, has its recovery state cleared (completed).
TEST(TimeoutCleanup, RecoveryCompletesOnRenewedTraffic) {
    time_t t0 = fresh_base();
    ConnectionRegistry reg;
    auto group = make_group(t0);
    auto conn = make_conn(50001, t0 + 1); // traffic arrived after recovery began
    conn->set_recovery_start(t0);
    group->add_connection(conn);
    reg.add_group(group);

    // last_received(t0+1) > recovery_start(t0) AND (ts - recovery_start) > 5.
    reg.cleanup_inactive(t0 + RECOVERY_CHANCE_PERIOD + 1, nullptr);

    ASSERT_EQ(reg.groups()[0]->connections().size(), 1u) << "still well within CONN_TIMEOUT";
    EXPECT_EQ(conn->recovery_start(), 0) << "recovery cleared after renewed traffic";
}

// A recovering connection with no renewed traffic, observed past
// RECOVERY_CHANCE_PERIOD, has its recovery attempt abandoned (failed).
TEST(TimeoutCleanup, RecoveryFailsWithoutRenewedTraffic) {
    time_t t0 = fresh_base();
    ConnectionRegistry reg;
    auto group = make_group(t0);
    auto conn = make_conn(50001, t0); // last_received == recovery_start: no new traffic
    conn->set_recovery_start(t0);
    group->add_connection(conn);
    reg.add_group(group);

    // last_received NOT > recovery_start, and recovery_start + 5 < ts.
    reg.cleanup_inactive(t0 + RECOVERY_CHANCE_PERIOD + 1, nullptr);

    ASSERT_EQ(reg.groups()[0]->connections().size(), 1u) << "not yet past CONN_TIMEOUT";
    EXPECT_EQ(conn->recovery_start(), 0) << "recovery attempt abandoned after the window";
}

// cleanup_inactive runs at most once per CLEANUP_PERIOD. A second call within
// the period is a no-op even when a connection has since crossed CONN_TIMEOUT;
// the call after the period elapses does the removal.
TEST(TimeoutCleanup, CleanupThrottledWithinPeriod) {
    time_t t0 = fresh_base();
    ConnectionRegistry reg;
    auto group = make_group(t0);
    group->add_connection(make_conn(50001, t0 - 4)); // 4s stale at t0
    reg.add_group(group);

    // Run 1 @ t0+10: 14s silence (< 15) -> retained; arms last_run = t0+10.
    reg.cleanup_inactive(t0 + 10, nullptr);
    ASSERT_EQ(reg.groups()[0]->connections().size(), 1u);

    // Run 2 @ t0+12 (< last_run + CLEANUP_PERIOD): THROTTLED. Although 16s
    // silence now exceeds CONN_TIMEOUT, the body is skipped and the conn stays.
    reg.cleanup_inactive(t0 + 12, nullptr);
    EXPECT_EQ(reg.groups()[0]->connections().size(), 1u)
        << "second cleanup within CLEANUP_PERIOD must be a no-op";

    // Run 3 @ t0+14 (> last_run + CLEANUP_PERIOD): runs, 18s silence -> removed.
    reg.cleanup_inactive(t0 + 14, nullptr);
    EXPECT_EQ(reg.groups()[0]->connections().size(), 0u)
        << "cleanup must resume after CLEANUP_PERIOD elapses";
}

// Documents that the throttle constant is the small cellular-friendly value the
// reaper assumes; if Task 15 retunes it, the throttle test bounds above move.
TEST(TimeoutCleanup, CleanupPeriodConstantIsThreeSeconds) {
    EXPECT_EQ(CLEANUP_PERIOD, 3);
}

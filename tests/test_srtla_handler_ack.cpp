/*
    srtla - SRT transport proxy with link aggregation
    Copyright (C) 2026 CeraLive

    Post-merge ACK behavior characterization.

    Diff vs the pre-merge version of this file (in commit history):
    upstream commit a89aa74 ("fix(receiver): remove SRTLA ACK throttling")
    deleted:
      * receiver_config.h: ACK_THROTTLE_INTERVAL and MIN_ACK_RATE
      * ConnectionStats: ack_throttle_factor, last_ack_sent_time,
        legacy_ack_throttle_factor
      * srtla_handler.cpp: the time-gated `if (current_ms < last_ack_sent
        + ACK_THROTTLE_INTERVAL/factor)` skip path
      * load_balancer.cpp: the throttle computation inside
        `LoadBalancer::adjust_weights`

    SRTLA ACKs are now sent unconditionally every RECV_ACK_INT packets,
    matching BELABOX/Moblin behavior and avoiding the window-feedback
    bug upstream documented.

    These tests assert the REPLACEMENT behavior:
      * No symbols related to ACK throttling exist on ConnectionStats.
      * `RECV_ACK_INT` is the controlling cadence (every N packets).
      * `LoadBalancer::adjust_weights` only mutates `weight_percent`;
        no per-connection throttle field is touched.
      * Cellular-resilience timeouts are the new upstream values.
*/

#include <gtest/gtest.h>

#include <cstring>
#include <ctime>
#include <memory>
#include <netinet/in.h>
#include <sys/socket.h>
#include <type_traits>

#include "connection/connection.h"
#include "connection/connection_group.h"
#include "quality/load_balancer.h"
#include "receiver_config.h"

using srtla::CONN_TIMEOUT;
using srtla::GROUP_TIMEOUT;
using srtla::RECV_ACK_INT;
using srtla::WEIGHT_CRITICAL;
using srtla::WEIGHT_FULL;
using srtla::connection::Connection;
using srtla::connection::ConnectionGroup;
using srtla::connection::ConnectionGroupPtr;
using srtla::quality::LoadBalancer;

namespace {

struct sockaddr_storage make_addr(uint16_t port) {
    struct sockaddr_storage ss;
    std::memset(&ss, 0, sizeof(ss));
    auto *in = reinterpret_cast<struct sockaddr_in *>(&ss);
    in->sin_family = AF_INET;
    in->sin_port = htons(port);
    in->sin_addr.s_addr = htonl(0x7f000001);
    return ss;
}

ConnectionGroupPtr make_group(time_t now, int n_conns) {
    char client_id[8] = {'t', 'e', 's', 't', 0, 0, 0, 0};
    auto group = std::make_shared<ConnectionGroup>(client_id, now);
    for (int i = 0; i < n_conns; ++i) {
        auto addr = make_addr(static_cast<uint16_t>(50000 + i));
        auto conn = std::make_shared<Connection>(addr, now);
        group->add_connection(conn);
    }
    return group;
}

void prime(ConnectionGroupPtr &g, time_t now) {
    g->set_load_balancing_enabled(true);
    g->set_last_quality_eval(now);
    g->set_last_load_balance_eval(now - 1);
}

// Compile-time check that a type does NOT have a member of a given name.
// Used to detection-test removal of ack_throttle_factor / last_ack_sent_time.
template <typename, typename = std::void_t<>>
struct has_ack_throttle_factor : std::false_type {};
template <typename T>
struct has_ack_throttle_factor<T, std::void_t<decltype(std::declval<T>().ack_throttle_factor)>>
    : std::true_type {};

template <typename, typename = std::void_t<>>
struct has_last_ack_sent_time : std::false_type {};
template <typename T>
struct has_last_ack_sent_time<T, std::void_t<decltype(std::declval<T>().last_ack_sent_time)>>
    : std::true_type {};

} // namespace

// -- Removed-symbol checks ---------------------------------------------------

TEST(AckBehaviorPostMerge, ConnectionStatsHasNoThrottleFields) {
    static_assert(!has_ack_throttle_factor<srtla::ConnectionStats>::value,
                  "ack_throttle_factor must be absent post-merge");
    static_assert(!has_last_ack_sent_time<srtla::ConnectionStats>::value,
                  "last_ack_sent_time must be absent post-merge");
    SUCCEED();
}

// -- Replacement constant ----------------------------------------------------

TEST(AckBehaviorPostMerge, AckCadenceIsRecvAckInt) {
    EXPECT_EQ(RECV_ACK_INT, 10u);
}

// -- Cellular-resilience timeouts (new upstream values) ----------------------

TEST(AckBehaviorPostMerge, GroupTimeoutMatchesUpstreamCellularValue) {
    EXPECT_EQ(GROUP_TIMEOUT, 30);
}

TEST(AckBehaviorPostMerge, ConnTimeoutMatchesUpstreamCellularValue) {
    EXPECT_EQ(CONN_TIMEOUT, 15);
}

// -- Connection-level invariant ----------------------------------------------

TEST(AckBehaviorPostMerge, NewConnectionStartsAtFullWeight) {
    auto addr = make_addr(50000);
    auto conn = std::make_shared<Connection>(addr, 1000);
    EXPECT_EQ(conn->stats().weight_percent, WEIGHT_FULL);
    EXPECT_EQ(conn->stats().error_points, 0u);
}

// -- LoadBalancer no longer modifies any throttle state ----------------------
//
// The mutation surface of LoadBalancer::adjust_weights is now restricted to
// `weight_percent` (and indirectly the bookkeeping fields
// `last_load_balance_eval`). With load balancing enabled and a critically
// degraded peer, the weight changes but no per-connection throttle field
// exists to be touched.
TEST(AckBehaviorPostMerge, LoadBalancerOnlyMutatesWeight) {
    LoadBalancer lb;
    time_t now = 100000;
    auto group = make_group(now, 2);
    group->connections()[0]->stats().error_points = 0;
    group->connections()[1]->stats().error_points = 40;
    prime(group, now);

    lb.adjust_weights(group, now);

    EXPECT_EQ(group->connections()[0]->stats().weight_percent, WEIGHT_FULL);
    EXPECT_EQ(group->connections()[1]->stats().weight_percent, WEIGHT_CRITICAL);
}

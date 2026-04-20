/*
    srtla - SRT transport proxy with link aggregation
    Copyright (C) 2026 CeraLive

    Pre-merge characterization of SRTLA ACK throttling behavior.

    The current CERALIVE/srtla codebase exposes time-gated ACK throttling
    via:
      * receiver_config.h constants ACK_THROTTLE_INTERVAL (100 ms) and
        MIN_ACK_RATE (0.2).
      * ConnectionStats fields `ack_throttle_factor` (default 1.0) and
        `last_ack_sent_time` (default 0).
      * LoadBalancer::adjust_weights() mutating `ack_throttle_factor`
        when load balancing is enabled and there are 2+ active conns.

    Upstream commit a89aa74 removes all of the above. Once the merge
    lands, this test is rewritten in T3d to assert the inverse:
    "no time-based ACK suppression exists; ACK is sent every
     RECV_ACK_INT packets unconditionally". When that happens, the
    symbols below will be gone and this file will be replaced wholesale
    so the post-merge expectation is reviewable as a test diff.
*/

#include <gtest/gtest.h>

#include <cstring>
#include <ctime>
#include <memory>
#include <netinet/in.h>
#include <sys/socket.h>

#include "connection/connection.h"
#include "connection/connection_group.h"
#include "quality/load_balancer.h"
#include "receiver_config.h"

using srtla::ACK_THROTTLE_INTERVAL;
using srtla::MIN_ACK_RATE;
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

} // namespace

// Constants exist with the documented values.
TEST(AckThrottlingPreMerge, ConstantsHaveExpectedValues) {
    EXPECT_EQ(ACK_THROTTLE_INTERVAL, 100);
    EXPECT_DOUBLE_EQ(MIN_ACK_RATE, 0.2);
}

// New connections start unthrottled.
TEST(AckThrottlingPreMerge, NewConnectionStartsUnthrottled) {
    auto addr = make_addr(50000);
    auto conn = std::make_shared<Connection>(addr, 1000);
    EXPECT_DOUBLE_EQ(conn->stats().ack_throttle_factor, 1.0);
    EXPECT_EQ(conn->stats().last_ack_sent_time, 0u);
}

// With load balancing and a critically degraded connection vs a healthy one,
// the bad connection's ack_throttle_factor is reduced below 1.0 and clamped
// at MIN_ACK_RATE.
TEST(AckThrottlingPreMerge, LoadBalancerThrottlesWorseConnection) {
    LoadBalancer lb;
    time_t now = 100000;
    auto group = make_group(now, 2);
    group->connections()[0]->stats().error_points = 0;   // WEIGHT_FULL
    group->connections()[1]->stats().error_points = 40;  // WEIGHT_CRITICAL
    prime(group, now);

    lb.adjust_weights(group, now);

    EXPECT_DOUBLE_EQ(group->connections()[0]->stats().ack_throttle_factor, 1.0);
    EXPECT_LT(group->connections()[1]->stats().ack_throttle_factor, 1.0);
    EXPECT_GE(group->connections()[1]->stats().ack_throttle_factor, MIN_ACK_RATE);
}

// With load balancing disabled, throttle factor is reset to 1.0 regardless of
// per-connection error_points.
TEST(AckThrottlingPreMerge, DisablingLoadBalancingClearsThrottle) {
    LoadBalancer lb;
    time_t now = 100000;
    auto group = make_group(now, 2);
    group->connections()[0]->stats().error_points = 0;
    group->connections()[1]->stats().error_points = 40;
    group->connections()[1]->stats().ack_throttle_factor = 0.3; // pretend throttled

    group->set_load_balancing_enabled(false);
    group->set_last_quality_eval(now);
    group->set_last_load_balance_eval(now - 100);

    lb.adjust_weights(group, now);
    EXPECT_DOUBLE_EQ(group->connections()[1]->stats().ack_throttle_factor, 1.0);
}

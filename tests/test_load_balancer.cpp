/*
    srtla - SRT transport proxy with link aggregation
    Copyright (C) 2026 CeraLive

    Characterization tests for srtla::quality::LoadBalancer::adjust_weights.

    Locks in the weight-from-error-points mapping currently in
    src/quality/load_balancer.cpp so any unintended change after the
    upstream merge is detected mechanically.

    Mapping (from current code):
        error_points >= 40   -> WEIGHT_CRITICAL  (10)
        error_points >= 25   -> WEIGHT_POOR      (40)
        error_points >= 15   -> WEIGHT_FAIR      (55)
        error_points >= 10   -> WEIGHT_DEGRADED  (70)
        error_points >=  5   -> WEIGHT_EXCELLENT (85)
        else                 -> WEIGHT_FULL      (100)
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

using srtla::WEIGHT_CRITICAL;
using srtla::WEIGHT_DEGRADED;
using srtla::WEIGHT_EXCELLENT;
using srtla::WEIGHT_FAIR;
using srtla::WEIGHT_FULL;
using srtla::WEIGHT_POOR;
using srtla::connection::Connection;
using srtla::connection::ConnectionGroup;
using srtla::connection::ConnectionGroupPtr;
using srtla::connection::ConnectionPtr;
using srtla::quality::LoadBalancer;

namespace {

struct sockaddr_storage make_addr(uint16_t port) {
    struct sockaddr_storage ss;
    std::memset(&ss, 0, sizeof(ss));
    auto *in = reinterpret_cast<struct sockaddr_in *>(&ss);
    in->sin_family = AF_INET;
    in->sin_port = htons(port);
    in->sin_addr.s_addr = htonl(0x7f000001); // 127.0.0.1
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

// Force load_balancer to actually run by ensuring last_quality_eval > last_load_balance_eval
// and load_balancing_enabled is true.
void prime_for_eval(ConnectionGroupPtr &group, time_t now) {
    group->set_load_balancing_enabled(true);
    group->set_last_quality_eval(now);
    group->set_last_load_balance_eval(now - 1);
}

} // namespace

// -- weight mapping (the part that survives the upstream merge) ---------------

TEST(LoadBalancerWeights, CriticalAt40ErrorPoints) {
    LoadBalancer lb;
    time_t now = 100000;
    auto group = make_group(now, 1);
    group->connections()[0]->stats().error_points = 40;
    prime_for_eval(group, now);

    lb.adjust_weights(group, now);
    EXPECT_EQ(group->connections()[0]->stats().weight_percent, WEIGHT_CRITICAL);
}

TEST(LoadBalancerWeights, PoorAt25ErrorPoints) {
    LoadBalancer lb;
    time_t now = 100000;
    auto group = make_group(now, 1);
    group->connections()[0]->stats().error_points = 25;
    prime_for_eval(group, now);

    lb.adjust_weights(group, now);
    EXPECT_EQ(group->connections()[0]->stats().weight_percent, WEIGHT_POOR);
}

TEST(LoadBalancerWeights, FairAt15ErrorPoints) {
    LoadBalancer lb;
    time_t now = 100000;
    auto group = make_group(now, 1);
    group->connections()[0]->stats().error_points = 15;
    prime_for_eval(group, now);

    lb.adjust_weights(group, now);
    EXPECT_EQ(group->connections()[0]->stats().weight_percent, WEIGHT_FAIR);
}

TEST(LoadBalancerWeights, DegradedAt10ErrorPoints) {
    LoadBalancer lb;
    time_t now = 100000;
    auto group = make_group(now, 1);
    group->connections()[0]->stats().error_points = 10;
    prime_for_eval(group, now);

    lb.adjust_weights(group, now);
    EXPECT_EQ(group->connections()[0]->stats().weight_percent, WEIGHT_DEGRADED);
}

TEST(LoadBalancerWeights, ExcellentAt5ErrorPoints) {
    LoadBalancer lb;
    time_t now = 100000;
    auto group = make_group(now, 1);
    group->connections()[0]->stats().error_points = 5;
    prime_for_eval(group, now);

    lb.adjust_weights(group, now);
    EXPECT_EQ(group->connections()[0]->stats().weight_percent, WEIGHT_EXCELLENT);
}

TEST(LoadBalancerWeights, FullAtZeroErrorPoints) {
    LoadBalancer lb;
    time_t now = 100000;
    auto group = make_group(now, 1);
    group->connections()[0]->stats().error_points = 0;
    prime_for_eval(group, now);

    lb.adjust_weights(group, now);
    EXPECT_EQ(group->connections()[0]->stats().weight_percent, WEIGHT_FULL);
}

TEST(LoadBalancerWeights, MultipleConnectionsGetIndependentWeights) {
    LoadBalancer lb;
    time_t now = 100000;
    auto group = make_group(now, 3);
    group->connections()[0]->stats().error_points = 0;
    group->connections()[1]->stats().error_points = 5;
    group->connections()[2]->stats().error_points = 25;
    prime_for_eval(group, now);

    lb.adjust_weights(group, now);
    EXPECT_EQ(group->connections()[0]->stats().weight_percent, WEIGHT_FULL);
    EXPECT_EQ(group->connections()[1]->stats().weight_percent, WEIGHT_EXCELLENT);
    EXPECT_EQ(group->connections()[2]->stats().weight_percent, WEIGHT_POOR);
}

TEST(LoadBalancerWeights, EmptyGroupNoCrash) {
    LoadBalancer lb;
    time_t now = 100000;
    auto group = make_group(now, 0);
    prime_for_eval(group, now);
    lb.adjust_weights(group, now); // must not crash
    SUCCEED();
}

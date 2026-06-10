/*
    srtla - SRT transport proxy with link aggregation
    Copyright (C) 2026 CeraLive

    Hardening reproducers — Family 2 (MAX_GROUPS exhaustion).

    The receiver caps live groups at MAX_GROUPS (200, src/receiver_config.h).
    register_group() rejects the (MAX_GROUPS+1)-th REG1 with REG_ERR before
    creating anything (see src/protocol/srtla_handler.cpp:193). These tests
    drive that guard through the real handler over loopback UDP and assert:

      * at the cap, REG1 is answered with REG_ERR — promptly, and never with a
        silent drop (a reply MUST come back);
      * one below the cap, REG1 still succeeds (REG2), so the limit is exactly
        MAX_GROUPS and not off-by-one;
      * freeing one slot lets a retry succeed;
      * 200-group registration churn does not leak resident memory.

    Groups are pre-loaded straight into the registry (the "mock groups" loop) so
    the test stays at handler granularity without standing up 200 real sockets;
    the (MAX_GROUPS+1)-th REG1 is then a genuine on-the-wire packet.

    These are regression pins, not RED tests — the guard exists today. The
    *exhaustion vector itself* (a sender able to mint unbounded groups via
    repeated distinct REG1s, since register_group does not dedupe by id) is the
    hardening note recorded in tests/KNOWN_BUGS.md for Task 15.
*/

#include <gtest/gtest.h>

#include <unistd.h>

#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <vector>

#include "connection/connection_group.h"
#include "handler_harness.h"
#include "receiver_config.h"

using srtla::MAX_GROUPS;
using srtla::connection::ConnectionGroup;
using srtla::connection::ConnectionGroupPtr;
using srtla::test::Client;
using srtla::test::HandlerHarness;
using srtla::test::make_client_id;

namespace {

constexpr time_t kTs = 200000;

// A bare group with a unique id, no connections, no SRT socket — just enough to
// occupy a registry slot for the size guard.
ConnectionGroupPtr make_mock_group(uint32_t seed) {
    auto id = make_client_id(seed);
    return std::make_shared<ConnectionGroup>(reinterpret_cast<const char *>(id.data()), kTs);
}

void fill_registry(HandlerHarness &h, int count) {
    for (int i = 0; i < count; ++i) {
        h.registry().add_group(make_mock_group(static_cast<uint32_t>(i + 1)));
    }
}

// Resident set size in KiB from /proc/self/statm (field 2 = resident pages).
long resident_kib() {
    FILE *f = std::fopen("/proc/self/statm", "r");
    if (!f) {
        return -1;
    }
    long total_pages = 0;
    long resident_pages = 0;
    int got = std::fscanf(f, "%ld %ld", &total_pages, &resident_pages);
    std::fclose(f);
    if (got != 2) {
        return -1;
    }
    long page_kib = sysconf(_SC_PAGESIZE) / 1024;
    return resident_pages * page_kib;
}

} // namespace

// At exactly MAX_GROUPS, the next REG1 is rejected with REG_ERR (no new group).
TEST(GroupLimits, AtMaxGroups_Reg1GetsRegErr) {
    HandlerHarness h;
    fill_registry(h, MAX_GROUPS);
    ASSERT_EQ(h.registry().groups().size(), static_cast<size_t>(MAX_GROUPS));

    Client link = h.make_client();
    link.send_reg1(make_client_id(0xF00Du));
    h.pump(kTs);

    std::vector<uint8_t> reply;
    ASSERT_TRUE(link.recv_one(reply)) << "REG1 at cap must not be silently dropped";
    EXPECT_EQ(srtla::test::pkt_type(reply), SRTLA_TYPE_REG_ERR);
    EXPECT_EQ(h.registry().groups().size(), static_cast<size_t>(MAX_GROUPS))
        << "rejected REG1 must not create a group";
}

// One slot free: REG1 is accepted (REG2) and the group count rises by one.
TEST(GroupLimits, OneBelowMax_Reg1Succeeds) {
    HandlerHarness h;
    fill_registry(h, MAX_GROUPS - 1);

    Client link = h.make_client();
    link.send_reg1(make_client_id(0xBEEFu));
    h.pump(kTs);

    std::vector<uint8_t> reply;
    ASSERT_TRUE(link.recv_one(reply));
    EXPECT_EQ(srtla::test::pkt_type(reply), SRTLA_TYPE_REG2);
    EXPECT_EQ(h.registry().groups().size(), static_cast<size_t>(MAX_GROUPS));
}

// The rejection is prompt and explicit: a reply arrives (no silent drop) and it
// is REG_ERR, well within the 2s budget the task sets.
TEST(GroupLimits, AtMax_Reg1RejectedPromptlyNotDropped) {
    HandlerHarness h;
    fill_registry(h, MAX_GROUPS);

    Client link = h.make_client();
    auto t0 = std::chrono::steady_clock::now();
    link.send_reg1(make_client_id(0x1234u));
    h.pump(kTs);
    std::vector<uint8_t> reply;
    bool got = link.recv_one(reply);
    auto elapsed = std::chrono::steady_clock::now() - t0;

    ASSERT_TRUE(got) << "no reply == silent drop (forbidden)";
    EXPECT_EQ(srtla::test::pkt_type(reply), SRTLA_TYPE_REG_ERR);
    EXPECT_LT(std::chrono::duration_cast<std::chrono::milliseconds>(elapsed).count(), 2000)
        << "REG_ERR must come back within 2s";
}

// Freeing one slot lets the previously-rejected sender's retry succeed.
TEST(GroupLimits, DeregisterOne_Reg1RetrySucceeds) {
    HandlerHarness h;
    fill_registry(h, MAX_GROUPS);

    Client link = h.make_client();
    link.send_reg1(make_client_id(0x5151u));
    h.pump(kTs);
    {
        std::vector<uint8_t> reply;
        ASSERT_TRUE(link.recv_one(reply));
        ASSERT_EQ(srtla::test::pkt_type(reply), SRTLA_TYPE_REG_ERR);
    }

    // Operator/cleanup frees a slot.
    h.registry().remove_group(h.registry().groups().front());
    ASSERT_EQ(h.registry().groups().size(), static_cast<size_t>(MAX_GROUPS - 1));

    link.send_reg1(make_client_id(0x5151u));
    h.pump(kTs);
    std::vector<uint8_t> reply;
    ASSERT_TRUE(link.recv_one(reply)) << "retry after dereg must get a reply";
    EXPECT_EQ(srtla::test::pkt_type(reply), SRTLA_TYPE_REG2) << "freed slot => REG1 succeeds";
    EXPECT_EQ(h.registry().groups().size(), static_cast<size_t>(MAX_GROUPS));
}

// Registering and tearing down 200 groups many times must not leak resident
// memory. maxrss is a high-water mark, so we compare RSS after a warm-up burst
// against RSS after many further bursts: a steady leak keeps climbing, a
// leak-free path plateaus. Threshold is deliberately generous to stay non-flaky
// (allocator retention, page granularity).
TEST(GroupLimits, RepeatedGroupChurn_RssStable) {
    auto churn = []() {
        srtla::connection::ConnectionRegistry reg;
        for (int i = 0; i < MAX_GROUPS; ++i) {
            reg.add_group(make_mock_group(static_cast<uint32_t>(i + 1)));
        }
        // Drop them all (shared_ptr destruction frees the groups).
        reg.groups().clear();
    };

    // Warm up allocator arenas so the baseline is past first-touch growth.
    for (int r = 0; r < 5; ++r) {
        churn();
    }
    long rss_warm = resident_kib();
    ASSERT_GT(rss_warm, 0) << "could not read RSS";

    for (int r = 0; r < 50; ++r) {
        churn();
    }
    long rss_final = resident_kib();
    ASSERT_GT(rss_final, 0);

    long growth = rss_final - rss_warm;
    EXPECT_LT(growth, 4096)
        << "RSS grew " << growth << " KiB across 50x200 group churn (leak suspected)";
}

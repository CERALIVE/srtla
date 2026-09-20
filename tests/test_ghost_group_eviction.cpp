/*
    srtla - SRT transport proxy with link aggregation
    Copyright (C) 2026 CeraLive

    RED tests — ghost-group eviction (pre-cherry-pick of upstream 7855012).

    Unauthenticated REG1 packets create connection groups before any SRT
    handshake. Today an empty group is held for the full GROUP_TIMEOUT (30s) and
    the table is hard-capped at MAX_GROUPS with REG_ERR at the cap, so an
    attacker can flood "ghost" groups (registered, never streamed) and lock out
    the real broadcaster. Commit 7855012 hardens this:

      * a group that never forwarded real SRT data is reaped at the shorter
        PENDING_GROUP_TIMEOUT (5s) instead of GROUP_TIMEOUT (30s);
      * when the table is full, a new REG1 evicts the OLDEST ghost group before
        rejecting, instead of returning REG_ERR outright;
      * once a group forwards real SRT traffic it is promoted (mark_data_seen)
        and is no longer reaped early or evictable, so active streams and
        cellular reconnects survive a flood.

    This suite asserts that hardened behavior. It is RED on current main: the
    behavior is absent, so the discriminating cases below fail today and go
    green after the cherry-pick — with no edits to this file.

    Compile-on-main constraint. The cherry-pick adds new public symbols
    (ConnectionGroup::has_seen_data/mark_data_seen,
    ConnectionRegistry::evict_oldest_pending_group, and the
    PENDING_GROUP_TIMEOUT constant). Referencing any of them by name would break
    compilation on current main and turn "RED test" into "build failure". So the
    suite is written strictly against the public API that exists BOTH before and
    after the cherry-pick:

      * promotion (data_seen) is induced only through the production data path —
        a real SRT data packet pushed through SRTLAHandler, the sole caller of
        mark_data_seen() — never by touching the flag directly;
      * PENDING_GROUP_TIMEOUT (5s) is mirrored locally as kPendingGroupTimeout;
      * the reaper is driven by ConnectionRegistry::cleanup_inactive(ts, cb)
        through its injected logical clock — no wall-clock waits anywhere.

    Tests that need to distinguish before/after behavior assert on observable
    public effects (group survival, REG2 vs REG_ERR replies), so they read as a
    behavioral spec and pass unmodified once the fix lands.
*/

#include <gtest/gtest.h>

#include <endian.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <memory>
#include <vector>

#include "connection/connection.h"
#include "connection/connection_group.h"
#include "connection/connection_registry.h"
#include "handler_harness.h"
#include "receiver_config.h"

extern "C" {
#include "common.h"
}

using srtla::MAX_GROUPS;
using srtla::connection::Connection;
using srtla::connection::ConnectionGroup;
using srtla::connection::ConnectionGroupPtr;
using srtla::connection::ConnectionRegistry;
using srtla::test::Client;
using srtla::test::extract_full_id;
using srtla::test::HandlerHarness;
using srtla::test::make_client_id;
using srtla::test::pkt_type;

namespace {

// Local mirror of the PENDING_GROUP_TIMEOUT the cherry-pick adds to
// receiver_config.h (5s). Declared here so the suite compiles against current
// main, where the constant does not yet exist. Kept well below GROUP_TIMEOUT
// (30s); every reaper advance in this file stays inside that window so a green
// result can only come from the pending-timeout path, never the 30s fallback.
constexpr time_t kPendingGroupTimeout = 5;

// Strictly-increasing, far-apart logical time base per test. cleanup_inactive
// keeps a process-static `last_run` (shared across every ConnectionRegistry
// instance), so each test must start above the previous test's timestamps for
// its first cleanup to clear the once-per-CLEANUP_PERIOD throttle regardless of
// execution order (including --gtest_shuffle). Mirrors test_timeout_cleanup.cpp.
time_t fresh_base() {
    static std::atomic<time_t> base{1'000'000};
    return base.fetch_add(1'000'000);
}

// A bare group with a unique id, no connections, no SRT socket and never having
// forwarded data: a "ghost" left behind by a REG1 flood. created_at is explicit
// so eviction's "oldest" choice is deterministic.
ConnectionGroupPtr make_ghost_group(uint32_t seed, time_t created_at) {
    auto id = make_client_id(seed);
    return std::make_shared<ConnectionGroup>(reinterpret_cast<const char *>(id.data()), created_at);
}

bool group_present(const ConnectionRegistry &reg, const ConnectionGroupPtr &g) {
    const auto &groups = reg.groups();
    return std::find(groups.begin(), groups.end(), g) != groups.end();
}

// Run a full REG1/REG2 handshake plus one real SRT data packet through the live
// handler so the resulting group is promoted via the production mark_data_seen
// path (post-cherry-pick) — without this file naming that method. The data
// packet is a minimal SRT data packet (high bit clear, >= SRT_MIN_LEN, not a
// REG/keepalive frame), so process_single_packet treats it as forwardable
// traffic. Returns the registered group with its connection still attached.
ConnectionGroupPtr register_streaming_group(HandlerHarness &h, Client &link,
                                            uint32_t seed, time_t ts) {
    link.send_reg1(make_client_id(seed));
    h.pump(ts);
    std::vector<uint8_t> reg2;
    EXPECT_TRUE(link.recv_one(reg2)) << "REG1 should be answered with REG2";
    EXPECT_EQ(pkt_type(reg2), SRTLA_TYPE_REG2);
    auto full_id = extract_full_id(reg2);

    link.send_reg2(full_id);
    h.pump(ts);
    std::vector<uint8_t> reg3;
    EXPECT_TRUE(link.recv_one(reg3)) << "REG2 should be answered with REG3";
    EXPECT_EQ(pkt_type(reg3), SRTLA_TYPE_REG3);

    ConnectionGroupPtr group =
        h.registry().find_group_by_id(reinterpret_cast<const char *>(full_id.data()));
    EXPECT_NE(group, nullptr) << "handshake must leave a registered group";

    // One real SRT data packet from the registered link. On the post-cherry-pick
    // handler this calls group->mark_data_seen(); on current main it only runs
    // metrics + forward. Either way it exercises the same public data path.
    std::array<uint8_t, SRT_MIN_LEN> data{};
    uint32_t sn = htobe32(1u); // high bit clear => SRT data packet, sn = 1
    std::memcpy(data.data(), &sn, sizeof(sn));
    (void)::send(link.fd(), data.data(), data.size(), 0);
    h.pump(ts);

    // Confirm the packet actually reached the forward path on both versions, so
    // a later "data-seen group survives" assertion can only be explained by the
    // promotion, not by the setup silently dropping the packet.
    if (group && !group->connections().empty()) {
        EXPECT_GE(group->connections().front()->stats().packets_received, 1u)
            << "the SRT data packet must reach SRTLAHandler's forward path";
    }
    return group;
}

// A loopback connection with a distinct source port, used to make a filler
// group non-evictable (connections() non-empty) without standing up a real
// handshake. Stands in for an active stream in the "nothing safe to evict" case.
std::shared_ptr<Connection> make_loopback_conn(uint16_t port, time_t ts) {
    struct sockaddr_storage ss;
    std::memset(&ss, 0, sizeof(ss));
    auto *in = reinterpret_cast<struct sockaddr_in *>(&ss);
    in->sin_family = AF_INET;
    in->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    in->sin_port = htons(port);
    return std::make_shared<Connection>(ss, ts);
}

} // namespace

// (a) A ghost group (registered, never forwarded SRT data) is reaped at
// PENDING_GROUP_TIMEOUT, not held for the full GROUP_TIMEOUT.
// RED on main: today an empty group survives until 30s, so it is still present
// at t0+6.
TEST(GhostGroupEviction, GhostGroupReapedAtPendingTimeout) {
    time_t t0 = fresh_base();
    ConnectionRegistry reg;
    reg.add_group(make_ghost_group(0x6057u, t0)); // no connections, never streamed

    // 6s of life: past PENDING_GROUP_TIMEOUT(5), far short of GROUP_TIMEOUT(30).
    reg.cleanup_inactive(t0 + kPendingGroupTimeout + 1, nullptr);

    EXPECT_EQ(reg.groups().size(), 0u)
        << "a never-streamed ghost group must be reaped at PENDING_GROUP_TIMEOUT, "
           "not held for the full GROUP_TIMEOUT";
}

// (a, lower boundary) A ghost younger than PENDING_GROUP_TIMEOUT is NOT reaped
// yet — the aggressive reap must not fire immediately. Passes before and after
// the fix; pins that the pending window is a window, not a zero-grace drop.
TEST(GhostGroupEviction, GhostGroupRetainedBeforePendingTimeout) {
    time_t t0 = fresh_base();
    ConnectionRegistry reg;
    reg.add_group(make_ghost_group(0x6057u, t0));

    // 4s: still inside PENDING_GROUP_TIMEOUT(5).
    reg.cleanup_inactive(t0 + kPendingGroupTimeout - 1, nullptr);

    EXPECT_EQ(reg.groups().size(), 1u)
        << "a ghost younger than PENDING_GROUP_TIMEOUT must not be reaped yet";
}

// (b) A flood that fills the table with ghost groups must not lock out a new
// registration: the oldest ghost is evicted and the REG1 is admitted (REG2).
// RED on main: at the cap a new REG1 is rejected with REG_ERR and no ghost is
// evicted.
TEST(GhostGroupEviction, FloodEvictsOldestGhostToAdmitRegistration) {
    time_t t0 = fresh_base();
    HandlerHarness h;

    for (int i = 0; i < MAX_GROUPS; ++i) {
        // created_at increases with i, so groups().front() is the oldest ghost.
        h.registry().add_group(make_ghost_group(static_cast<uint32_t>(i + 1), t0 + i));
    }
    ASSERT_EQ(h.registry().groups().size(), static_cast<size_t>(MAX_GROUPS));
    ConnectionGroupPtr oldest_ghost = h.registry().groups().front();

    Client newcomer = h.make_client();
    newcomer.send_reg1(make_client_id(0xFEEDu));
    h.pump(t0 + 1); // ts is just the new group's created_at; no reaper involved

    std::vector<uint8_t> reply;
    ASSERT_TRUE(newcomer.recv_one(reply)) << "registration at cap must not be silently dropped";
    EXPECT_EQ(pkt_type(reply), SRTLA_TYPE_REG2)
        << "a ghost flood must not lock out a new registration: the oldest ghost is "
           "evicted and the REG1 admitted (was REG_ERR before the fix)";
    EXPECT_FALSE(group_present(h.registry(), oldest_ghost))
        << "the oldest ghost group is the eviction victim";
    EXPECT_EQ(h.registry().groups().size(), static_cast<size_t>(MAX_GROUPS))
        << "table stays at the cap: one ghost out, one registration in";
}

// (c) A group that has forwarded real SRT data is promoted: it survives the
// pending-group reap while a never-streamed ghost beside it is reaped at the
// same 5s pass. RED on main: today the ghost is still alive at t0+6 (held to
// 30s), so the "ghost reaped" expectation fails.
TEST(GhostGroupEviction, DataSeenGroupSurvivesPendingReapWhileGhostReaped) {
    time_t t0 = fresh_base();
    HandlerHarness h;
    Client streamer = h.make_client();

    // A promoted (data-seen) group and a never-streamed ghost, both born at t0.
    ConnectionGroupPtr streamed = register_streaming_group(h, streamer, 0x57A1u, t0);
    ASSERT_NE(streamed, nullptr);
    ASSERT_FALSE(streamed->connections().empty());
    // Cellular reconnect: the uplink drops, the group goes empty but stays known.
    streamed->connections().clear();

    ConnectionGroupPtr ghost = make_ghost_group(0x6057u, t0);
    h.registry().add_group(ghost);

    // One reap pass at t0+6: past PENDING_GROUP_TIMEOUT(5), short of GROUP_TIMEOUT(30).
    h.registry().cleanup_inactive(t0 + kPendingGroupTimeout + 1, nullptr);

    EXPECT_TRUE(group_present(h.registry(), streamed))
        << "a group that forwarded real SRT data is promoted and must survive the "
           "pending-group reap (kept until GROUP_TIMEOUT like any active stream)";
    EXPECT_FALSE(group_present(h.registry(), ghost))
        << "the never-streamed ghost beside it must be reaped at PENDING_GROUP_TIMEOUT";
}

// (d) Eviction under table pressure never touches a data-seen group — even when
// it is the OLDEST group of all (reconnect-safety). The real broadcaster
// streamed, lost its link, and must keep its slot while a ghost is evicted for
// the newcomer. RED on main: the newcomer is rejected with REG_ERR and no ghost
// is evicted.
TEST(GhostGroupEviction, EvictionSkipsDataSeenGroupUnderTablePressure) {
    time_t t0 = fresh_base();
    HandlerHarness h;
    Client streamer = h.make_client();

    // Oldest group of all: registered and streamed at t0, then went empty.
    ConnectionGroupPtr streamed = register_streaming_group(h, streamer, 0xB0A7u, t0);
    ASSERT_NE(streamed, nullptr);
    ASSERT_FALSE(streamed->connections().empty());
    streamed->connections().clear();

    // Fill the rest of the table with never-streamed ghosts, all NEWER than the
    // broadcaster (created_at t0+1 .. these are creation stamps, not a reaper
    // clock advance — cleanup_inactive is never called in this test).
    for (int i = 0; i < MAX_GROUPS - 1; ++i) {
        h.registry().add_group(make_ghost_group(static_cast<uint32_t>(i + 1), t0 + 1 + i));
    }
    ASSERT_EQ(h.registry().groups().size(), static_cast<size_t>(MAX_GROUPS));

    // The eviction target is the oldest ghost (not the older, data-seen group).
    ConnectionGroupPtr oldest_ghost;
    for (const auto &g : h.registry().groups()) {
        if (g == streamed) {
            continue;
        }
        if (!oldest_ghost || g->created_at() < oldest_ghost->created_at()) {
            oldest_ghost = g;
        }
    }
    ASSERT_NE(oldest_ghost, nullptr);

    Client newcomer = h.make_client();
    newcomer.send_reg1(make_client_id(0xFEEDu));
    h.pump(t0 + 1);

    std::vector<uint8_t> reply;
    ASSERT_TRUE(newcomer.recv_one(reply)) << "registration at cap must get a reply";
    EXPECT_EQ(pkt_type(reply), SRTLA_TYPE_REG2)
        << "table full of ghosts: the newcomer must evict a ghost and be admitted";
    EXPECT_TRUE(group_present(h.registry(), streamed))
        << "the data-seen broadcaster must never be evicted, even as the oldest group "
           "(reconnect-safety)";
    EXPECT_FALSE(group_present(h.registry(), oldest_ghost))
        << "the oldest never-streamed ghost is the eviction victim";
}

// (d, contract guard) When the table is full but holds NO ghost — every group is
// actively connected or has streamed — there is nothing safe to evict, so a new
// registration is still refused with REG_ERR. Holds before AND after the fix:
// eviction reclaims only never-streamed ghosts and never steals a live slot.
TEST(GhostGroupEviction, AtMaxWithNoGhost_RegistrationStillRejected) {
    time_t t0 = fresh_base();
    HandlerHarness h;

    for (int i = 0; i < MAX_GROUPS; ++i) {
        ConnectionGroupPtr g = make_ghost_group(static_cast<uint32_t>(i + 1), t0 + i);
        // A live connection makes the group non-evictable (connections() non-empty),
        // standing in for an active stream without 200 real handshakes.
        g->add_connection(make_loopback_conn(static_cast<uint16_t>(20000 + i), t0));
        h.registry().add_group(g);
    }
    ASSERT_EQ(h.registry().groups().size(), static_cast<size_t>(MAX_GROUPS));

    Client newcomer = h.make_client();
    newcomer.send_reg1(make_client_id(0xFEEDu));
    h.pump(t0 + 1);

    std::vector<uint8_t> reply;
    ASSERT_TRUE(newcomer.recv_one(reply)) << "registration at cap must get a reply";
    EXPECT_EQ(pkt_type(reply), SRTLA_TYPE_REG_ERR)
        << "no ghost to reclaim => the REG_ERR cap contract is preserved";
    EXPECT_EQ(h.registry().groups().size(), static_cast<size_t>(MAX_GROUPS));
}

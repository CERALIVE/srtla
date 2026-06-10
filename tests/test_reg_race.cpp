/*
    srtla - SRT transport proxy with link aggregation
    Copyright (C) 2026 CeraLive

    Hardening reproducers — Family 1 (REG3/NGP race) and Family 5 (concurrent
    multi-interface registration).

    These exercise the real SRTLAHandler registration path over a loopback UDP
    socket (see handler_harness.h) under concurrent / out-of-order arrival of
    the second-phase REG2 packets that multiple bonded links emit at startup.

    Invariants asserted (the merged aa66a88 lineage is expected to hold them —
    the ecosystem REG3/NGP race fix landed upstream and is present here, so these
    are the regression net, not RED tests):

      * exactly one ConnectionGroup is created for one group id;
      * every link that sends a valid REG2 is eventually REG3'd (idempotently,
        even on a repeated REG2 from the same source);
      * a REG2 that arrives before its group exists yields exactly one REG_NGP
        (the documented "retry trigger"), never a multi-reply storm;
      * no crash across >=100 randomized-interleaving iterations.

    Any iteration that violated an invariant would be promoted to a
    *_KNOWNBUG test and recorded in tests/KNOWN_BUGS.md for Task 15.

    Protocol recap (see register_group / register_connection in
    src/protocol/srtla_handler.cpp): REG1 creates the *group* only (zero
    connections); each link — including the first — becomes a *connection* when
    its REG2 (carrying the receiver-completed id) is processed and answered with
    REG3. Additional links send REG2 directly.

    No SRT data packets are sent here, so the RECV_ACK_INT=10 ACK cadence is not
    involved and the SRT-forwarding path is never touched.
*/

#include <gtest/gtest.h>

#include <algorithm>
#include <array>
#include <numeric>
#include <random>
#include <vector>

#include "handler_harness.h"

using srtla::test::Client;
using srtla::test::HandlerHarness;
using srtla::test::make_client_id;
using srtla::test::ReplyTally;

namespace {

constexpr time_t kTs = 100000; // fixed logical clock; registration is time-agnostic here
constexpr int kRaceIterations = 100;

// Establish the group from `c0`'s REG1 and return the receiver-completed id.
// Fails the calling test (via gtest non-fatal) if no REG2 comes back.
std::array<uint8_t, SRTLA_ID_LEN> establish_group(HandlerHarness &h, Client &c0, uint32_t seed) {
    auto client_id = make_client_id(seed);
    c0.send_reg1(client_id);
    h.pump(kTs);
    std::vector<uint8_t> reply;
    bool got = c0.recv_one(reply);
    EXPECT_TRUE(got) << "REG1 produced no reply";
    EXPECT_EQ(srtla::test::pkt_type(reply), SRTLA_TYPE_REG2) << "REG1 reply was not REG2";
    return srtla::test::extract_full_id(reply);
}

} // namespace

// -- Family 1: REG3/NGP race ------------------------------------------------ //

// Three links of one group send their second-phase REG2 in a randomized order
// (modelling concurrent arrival within one recvmmsg batch). After the group
// already exists, every REG2 must find it -> REG3, with zero REG_NGP and a
// single group holding exactly three connections. Repeated >=100x for flakes.
TEST(RaceReg3Ngp, ConcurrentReg2AfterGroup_AllReg3NoNgp_100Iterations) {
    for (int iter = 0; iter < kRaceIterations; ++iter) {
        HandlerHarness h;
        std::vector<Client> links;
        links.reserve(3);
        for (int i = 0; i < 3; ++i) {
            links.emplace_back(h.make_client());
        }

        auto full_id = establish_group(h, links[0], static_cast<uint32_t>(iter + 1));
        links[0].drain(); // consume the REG2 from the establish step

        // Randomize which link's REG2 the handler sees first this iteration.
        std::array<int, 3> order = {0, 1, 2};
        std::mt19937 rng(static_cast<uint32_t>(iter * 2654435761u + 17u));
        std::shuffle(order.begin(), order.end(), rng);
        for (int idx : order) {
            links[static_cast<size_t>(idx)].send_reg2(full_id);
        }
        h.pump(kTs);

        ReplyTally tally;
        for (auto &link : links) {
            srtla::test::drain_into(link, tally);
        }

        ASSERT_EQ(h.registry().groups().size(), 1u)
            << "iter " << iter << ": expected exactly one group";
        ASSERT_EQ(h.registry().groups()[0]->connections().size(), 3u)
            << "iter " << iter << ": expected three registered connections";
        EXPECT_EQ(tally.reg3, 3) << "iter " << iter << ": every link should be REG3'd";
        EXPECT_EQ(tally.reg_ngp, 0) << "iter " << iter << ": no REG_NGP storm allowed";
        EXPECT_EQ(tally.reg_err, 0) << "iter " << iter << ": no REG_ERR expected";
    }
}

// A REG2 whose group does not exist yet (the BELABOX startup race documented in
// tests/compat/SMOKE_BASELINE.md) must get exactly ONE REG_NGP — the retry
// trigger — never a storm. The subsequent proper REG1->REG2 then succeeds with
// no further NGP.
TEST(RaceReg3Ngp, Reg2BeforeGroupExists_SingleNgpThenRecovers) {
    HandlerHarness h;
    Client link = h.make_client();

    // Premature REG2: full of an id that matches no group.
    link.send_reg2(make_client_id(0xABCDu));
    h.pump(kTs);

    ReplyTally pre;
    srtla::test::drain_into(link, pre);
    EXPECT_EQ(pre.reg_ngp, 1) << "unmatched REG2 must yield exactly one REG_NGP";
    EXPECT_EQ(pre.reg3, 0);
    EXPECT_EQ(pre.reg2, 0);

    // Now register properly: REG1 -> REG2 -> REG3.
    auto full_id = establish_group(h, link, 7u);
    link.drain();
    link.send_reg2(full_id);
    h.pump(kTs);

    ReplyTally post;
    srtla::test::drain_into(link, post);
    EXPECT_EQ(post.reg3, 1) << "proper REG2 must be REG3'd";
    EXPECT_EQ(post.reg_ngp, 0) << "no further NGP after the group exists";
    EXPECT_EQ(h.registry().groups().size(), 1u);
    EXPECT_EQ(h.registry().groups()[0]->connections().size(), 1u);
}

// A duplicate REG2 from an already-registered link must re-emit REG3 without
// adding a second connection (idempotent registration — the upstream fix that
// prevents a REG_NGP/duplicate-connection race on retransmit).
TEST(RaceReg3Ngp, RepeatedReg2SameLink_IdempotentReg3) {
    HandlerHarness h;
    Client link = h.make_client();

    auto full_id = establish_group(h, link, 11u);
    link.drain();

    for (int i = 0; i < 5; ++i) {
        link.send_reg2(full_id);
        h.pump(kTs);
        ReplyTally tally;
        srtla::test::drain_into(link, tally);
        EXPECT_EQ(tally.reg3, 1) << "repeat " << i << ": each REG2 should be answered with one REG3";
        EXPECT_EQ(tally.reg_ngp, 0) << "repeat " << i << ": no NGP";
        EXPECT_EQ(tally.reg_err, 0) << "repeat " << i << ": no REG_ERR";
    }

    ASSERT_EQ(h.registry().groups().size(), 1u);
    EXPECT_EQ(h.registry().groups()[0]->connections().size(), 1u)
        << "duplicate REG2 must not create duplicate connections";
}

// Full three-link registration cycle, repeated >=100x with fresh sockets each
// time, purely as a crash/leak-of-state smoke under repetition.
TEST(RaceReg3Ngp, ThreeLinkRegistration_Stress_NoCrash) {
    for (int iter = 0; iter < kRaceIterations; ++iter) {
        HandlerHarness h;
        Client c0 = h.make_client();
        auto full_id = establish_group(h, c0, static_cast<uint32_t>(1000 + iter));
        c0.drain();

        std::vector<Client> links;
        links.reserve(3);
        links.emplace_back(std::move(c0));
        links.emplace_back(h.make_client());
        links.emplace_back(h.make_client());
        for (auto &link : links) {
            link.send_reg2(full_id);
        }
        h.pump(kTs);

        ASSERT_EQ(h.registry().groups().size(), 1u) << "iter " << iter;
        ASSERT_EQ(h.registry().groups()[0]->connections().size(), 3u) << "iter " << iter;
    }
    SUCCEED();
}

// -- Family 5: concurrent multi-interface registration ---------------------- //

// Sender brings up three links simultaneously: one REG1 establishes the group,
// then all three REG2s arrive in the same window. Result must be a single group
// with three connections (no duplicate groups, no dropped links).
TEST(ConcurrentMultiInterface, ThreeReg2SameWindow_SingleGroupThreeConns) {
    HandlerHarness h;
    Client c0 = h.make_client();
    Client c1 = h.make_client();
    Client c2 = h.make_client();

    auto full_id = establish_group(h, c0, 5u);
    c0.drain();

    // All three REG2s queued before a single pump => one recvmmsg batch.
    c0.send_reg2(full_id);
    c1.send_reg2(full_id);
    c2.send_reg2(full_id);
    h.pump(kTs);

    ReplyTally tally;
    srtla::test::drain_into(c0, tally);
    srtla::test::drain_into(c1, tally);
    srtla::test::drain_into(c2, tally);

    ASSERT_EQ(h.registry().groups().size(), 1u);
    EXPECT_EQ(h.registry().groups()[0]->connections().size(), 3u);
    EXPECT_EQ(tally.reg3, 3);
    EXPECT_EQ(tally.reg_ngp, 0);
    EXPECT_EQ(tally.reg_err, 0);
}

// Current-behavior pin: each REG1 — even with an identical id first-half from
// distinct source addresses — creates a *distinct* group (register_group does
// not dedupe by id). A well-behaved sender only ever emits REG1 from link 0, so
// this never bites in practice; it is pinned because it is also the lever behind
// the MAX_GROUPS exhaustion vector (see test_group_limits.cpp and
// tests/KNOWN_BUGS.md). If Task 15 adds id-based dedupe, this expectation flips.
TEST(ConcurrentMultiInterface, DuplicateReg1SameIdHalf_CreatesDistinctGroups) {
    HandlerHarness h;
    Client a = h.make_client();
    Client b = h.make_client();
    Client c = h.make_client();

    auto id = make_client_id(99u);
    a.send_reg1(id);
    b.send_reg1(id);
    c.send_reg1(id);
    h.pump(kTs);

    EXPECT_EQ(h.registry().groups().size(), 3u)
        << "register_group currently creates one group per REG1, regardless of id";
    // No crash, every REG1 answered with a REG2 (no silent drop).
    ReplyTally tally;
    srtla::test::drain_into(a, tally);
    srtla::test::drain_into(b, tally);
    srtla::test::drain_into(c, tally);
    EXPECT_EQ(tally.reg2, 3);
}

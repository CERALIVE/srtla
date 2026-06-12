/*
    srtla - SRT transport proxy with link aggregation
    Copyright (C) 2026 CeraLive

    Locks the per-source-IP SRT auth-failure throttle introduced by upstream
    cherry-pick 39e324a (src/utils/auth_rate_limiter.{cpp,h}) plus the
    is_srt_shutdown classifier that drives the receiver's failed-auth signal.

    The limiter takes wall-clock time as an explicit `time_t now` parameter on
    every method, so these tests advance time by passing values -- no real
    waits, no clock injection needed. Thresholds (5 failures / 60s window / 60s
    cooldown) are the picked values, pinned by the static_asserts below; the
    behavioral cases assert the algorithm relative to those named constants.
*/

#include <gtest/gtest.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

#include <cstdint>
#include <cstring>

#include "receiver_config.h"
#include "utils/auth_rate_limiter.h"

extern "C" {
#include "common.h"
}

using srtla::utils::AuthRateLimiter;

static_assert(srtla::AUTH_FAIL_THRESHOLD == 5, "picked threshold (39e324a)");
static_assert(srtla::AUTH_FAIL_WINDOW == 60, "picked window seconds (39e324a)");
static_assert(srtla::AUTH_FAIL_COOLDOWN == 60, "picked cooldown seconds (39e324a)");

namespace {

constexpr int kThreshold = srtla::AUTH_FAIL_THRESHOLD;
constexpr int kWindow = srtla::AUTH_FAIL_WINDOW;
constexpr int kCooldown = srtla::AUTH_FAIL_COOLDOWN;

// Non-zero base so test timestamps never collide with the window_start==0
// "uninitialized" sentinel inside the limiter.
constexpr time_t kBase = 100000;

struct sockaddr_storage make_addr_v4(const char *ip, uint16_t port) {
    struct sockaddr_storage ss {};
    auto *a = reinterpret_cast<struct sockaddr_in *>(&ss);
    a->sin_family = AF_INET;
    a->sin_port = htons(port);
    inet_pton(AF_INET, ip, &a->sin_addr);
    return ss;
}

void make_control_packet(uint8_t *out, uint16_t srt_type) {
    std::memset(out, 0, 16);
    uint16_t type_be = htons(srt_type);
    std::memcpy(out, &type_be, sizeof(type_be));
}

} // namespace

// (a) record_failure accrues per source IP; below threshold stays allowed.
TEST(AuthRateLimiter, RecordFailureCountsPerSourceIpBelowThreshold) {
    AuthRateLimiter rl;
    auto attacker = make_addr_v4("203.0.113.10", 40000);
    for (int i = 0; i < kThreshold - 1; ++i) {
        rl.record_failure(attacker, kBase + i);
    }
    EXPECT_FALSE(rl.is_blocked(attacker, kBase + kThreshold));
    EXPECT_EQ(rl.tracked_entry_count(), 1u);
    EXPECT_FALSE(rl.is_blocked(make_addr_v4("203.0.113.99", 40000), kBase));
}

// (b) 5 failures inside the 60s window -> the 6th registration is BLOCKED.
TEST(AuthRateLimiter, FifthFailureInWindowBlocksSixthRegistration) {
    AuthRateLimiter rl;
    auto attacker = make_addr_v4("203.0.113.10", 40000);
    for (int i = 0; i < kThreshold; ++i) {
        rl.record_failure(attacker, kBase + i);
    }
    EXPECT_TRUE(rl.is_blocked(attacker, kBase + kThreshold));
}

// (c) 5 failures spread so no 5 land in any 60s window -> never blocked.
TEST(AuthRateLimiter, FailuresSpreadAcrossSlidingWindowNeverBlock) {
    AuthRateLimiter rl;
    auto attacker = make_addr_v4("203.0.113.10", 40000);
    const time_t offsets[] = {0, 30, 65, 95, 130};
    for (time_t off : offsets) {
        rl.record_failure(attacker, kBase + off);
    }
    EXPECT_FALSE(rl.is_blocked(attacker, kBase + 130));
    EXPECT_FALSE(rl.is_blocked(attacker, kBase + 200));
}

// (d) A blocked IP unblocks once the 60s cooldown elapses (strict expiry).
TEST(AuthRateLimiter, BlockedIpUnblocksAfterCooldownElapses) {
    AuthRateLimiter rl;
    auto attacker = make_addr_v4("203.0.113.10", 40000);
    for (int i = 0; i < kThreshold; ++i) {
        rl.record_failure(attacker, kBase + i);
    }
    const time_t tripped = kBase + (kThreshold - 1);
    EXPECT_TRUE(rl.is_blocked(attacker, tripped + 1));
    EXPECT_TRUE(rl.is_blocked(attacker, tripped + kCooldown - 1));
    EXPECT_FALSE(rl.is_blocked(attacker, tripped + kCooldown));
    EXPECT_FALSE(rl.is_blocked(attacker, tripped + kCooldown + 1));
}

// (e) Keys are IP-only: rotating the source port does not evade the block.
TEST(AuthRateLimiter, IpKeyingPortRotationDoesNotEvadeBlock) {
    AuthRateLimiter rl;
    for (int i = 0; i < kThreshold; ++i) {
        rl.record_failure(make_addr_v4("203.0.113.10", 40000 + i), kBase + i);
    }
    EXPECT_TRUE(rl.is_blocked(make_addr_v4("203.0.113.10", 55555), kBase + kThreshold));
    EXPECT_EQ(rl.tracked_entry_count(), 1u);
}

// (f) Distinct IPs are independent: a tripped attacker does not lock out a
// separate neighbor sitting at 4 (below-threshold) failures.
TEST(AuthRateLimiter, DistinctIpsAreIndependentNeighborNotLockedOut) {
    AuthRateLimiter rl;
    auto attacker = make_addr_v4("203.0.113.10", 40000);
    auto neighbor = make_addr_v4("203.0.113.11", 40000);
    for (int i = 0; i < kThreshold; ++i) {
        rl.record_failure(attacker, kBase + i);
    }
    for (int i = 0; i < kThreshold - 1; ++i) {
        rl.record_failure(neighbor, kBase + i);
    }
    EXPECT_TRUE(rl.is_blocked(attacker, kBase + kThreshold));
    EXPECT_FALSE(rl.is_blocked(neighbor, kBase + kThreshold));
}

// (g) cleanup reclaims stale entries, but retains active windows / live blocks.
TEST(AuthRateLimiter, StaleEntryCleanupReclaimsExpiredEntries) {
    AuthRateLimiter rl;

    auto idle = make_addr_v4("203.0.113.10", 40000);
    rl.record_failure(idle, kBase);
    EXPECT_EQ(rl.tracked_entry_count(), 1u);
    rl.cleanup(kBase + 1);
    EXPECT_EQ(rl.tracked_entry_count(), 1u);
    rl.cleanup(kBase + kWindow + 1);
    EXPECT_EQ(rl.tracked_entry_count(), 0u);

    auto blocked = make_addr_v4("203.0.113.20", 40000);
    for (int i = 0; i < kThreshold; ++i) {
        rl.record_failure(blocked, kBase + i);
    }
    const time_t tripped = kBase + (kThreshold - 1);
    rl.cleanup(tripped + 1);
    EXPECT_EQ(rl.tracked_entry_count(), 1u);
    rl.cleanup(tripped + kCooldown);
    EXPECT_EQ(rl.tracked_entry_count(), 0u);
}

// (h) is_srt_shutdown recognizes a SHUTDOWN and rejects other control packets.
TEST(IsSrtShutdown, ClassifiesShutdownAndRejectsOtherControlPackets) {
    uint8_t pkt[16];

    make_control_packet(pkt, SRT_TYPE_SHUTDOWN);
    EXPECT_TRUE(is_srt_shutdown(pkt, sizeof(pkt)));

    make_control_packet(pkt, SRT_TYPE_ACK);
    EXPECT_FALSE(is_srt_shutdown(pkt, sizeof(pkt)));
    make_control_packet(pkt, SRT_TYPE_NAK);
    EXPECT_FALSE(is_srt_shutdown(pkt, sizeof(pkt)));
    make_control_packet(pkt, SRT_TYPE_HANDSHAKE);
    EXPECT_FALSE(is_srt_shutdown(pkt, sizeof(pkt)));
}

TEST(IsSrtShutdown, ShortPacketIsNotShutdown) {
    uint8_t one_byte[1] = {0x80};
    EXPECT_FALSE(is_srt_shutdown(one_byte, 1));
}

// SRT data packets clear the high bit of byte 0 -> never a control SHUTDOWN.
TEST(IsSrtShutdown, DataPacketIsNotShutdown) {
    uint8_t data[16] = {0x00, 0x00, 0x00, 0x05};
    EXPECT_FALSE(is_srt_shutdown(data, sizeof(data)));
}

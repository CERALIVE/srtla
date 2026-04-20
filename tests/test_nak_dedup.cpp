/*
    srtla - SRT transport proxy with link aggregation
    Copyright (C) 2026 CeraLive

    Characterization tests for srtla::utils::NakDeduplicator.

    Locks in the current behavior of NAK deduplication so any unintended
    change after the upstream merge is detected mechanically.

    Constants captured (from src/utils/nak_dedup.h):
        SUPPRESS_MS = 100
        MAX_REPEATS = 1
*/

#include <gtest/gtest.h>

#include <cstdint>
#include <cstring>
#include <unordered_map>
#include <vector>

#include "utils/nak_dedup.h"

using srtla::utils::NakDeduplicator;
using srtla::utils::NakHashEntry;

namespace {

constexpr uint64_t kSuppressMs = 100;

// Build a synthetic NAK packet: 16-byte SRT header + payload bytes.
std::vector<uint8_t> make_nak_packet(const std::vector<uint8_t> &payload) {
    std::vector<uint8_t> pkt(16, 0);
    pkt.insert(pkt.end(), payload.begin(), payload.end());
    return pkt;
}

} // namespace

// -- hash_nak_payload ---------------------------------------------------------

TEST(NakDedupHash, ReturnsZeroForTooShortPayload) {
    std::vector<uint8_t> short_pkt(16, 0);
    EXPECT_EQ(NakDeduplicator::hash_nak_payload(short_pkt.data(),
                                                static_cast<int>(short_pkt.size()), -1),
              0u);

    std::vector<uint8_t> empty;
    EXPECT_EQ(NakDeduplicator::hash_nak_payload(empty.data(), 0, -1), 0u);
}

TEST(NakDedupHash, NonZeroForValidPayload) {
    auto pkt = make_nak_packet({0x01, 0x02, 0x03, 0x04});
    uint64_t h = NakDeduplicator::hash_nak_payload(pkt.data(),
                                                   static_cast<int>(pkt.size()), -1);
    EXPECT_NE(h, 0u);
}

TEST(NakDedupHash, DeterministicForSamePayload) {
    auto a = make_nak_packet({0xde, 0xad, 0xbe, 0xef});
    auto b = make_nak_packet({0xde, 0xad, 0xbe, 0xef});
    EXPECT_EQ(NakDeduplicator::hash_nak_payload(a.data(),
                                                static_cast<int>(a.size()), -1),
              NakDeduplicator::hash_nak_payload(b.data(),
                                                static_cast<int>(b.size()), -1));
}

TEST(NakDedupHash, DifferentForDifferentPayload) {
    auto a = make_nak_packet({0x01, 0x02, 0x03, 0x04});
    auto b = make_nak_packet({0x01, 0x02, 0x03, 0x05});
    EXPECT_NE(NakDeduplicator::hash_nak_payload(a.data(),
                                                static_cast<int>(a.size()), -1),
              NakDeduplicator::hash_nak_payload(b.data(),
                                                static_cast<int>(b.size()), -1));
}

TEST(NakDedupHash, PrefixBytesNarrowsScope) {
    auto a = make_nak_packet({0x01, 0x02, 0x03, 0x04, 0xff});
    auto b = make_nak_packet({0x01, 0x02, 0x03, 0x04, 0x00});
    // With prefix=4 only the first 4 payload bytes are hashed; trailing
    // differences are ignored.
    EXPECT_EQ(NakDeduplicator::hash_nak_payload(a.data(),
                                                static_cast<int>(a.size()), 4),
              NakDeduplicator::hash_nak_payload(b.data(),
                                                static_cast<int>(b.size()), 4));
}

// -- should_accept_nak --------------------------------------------------------

TEST(NakDedupAccept, AcceptsFirstSighting) {
    std::unordered_map<uint64_t, NakHashEntry> cache;
    EXPECT_TRUE(NakDeduplicator::should_accept_nak(cache, 0xABCD, 1000));
    ASSERT_EQ(cache.size(), 1u);
    EXPECT_EQ(cache[0xABCD].timestamp_ms, 1000u);
    EXPECT_EQ(cache[0xABCD].repeat_count, 0);
}

TEST(NakDedupAccept, RejectsWithinSuppressionWindow) {
    std::unordered_map<uint64_t, NakHashEntry> cache;
    ASSERT_TRUE(NakDeduplicator::should_accept_nak(cache, 0x1, 1000));
    EXPECT_FALSE(NakDeduplicator::should_accept_nak(cache, 0x1, 1000 + kSuppressMs - 1));
}

TEST(NakDedupAccept, AcceptsAfterSuppressionWindow) {
    std::unordered_map<uint64_t, NakHashEntry> cache;
    ASSERT_TRUE(NakDeduplicator::should_accept_nak(cache, 0x2, 1000));
    EXPECT_TRUE(NakDeduplicator::should_accept_nak(cache, 0x2, 1000 + kSuppressMs));
    EXPECT_EQ(cache[0x2].repeat_count, 1);
}

TEST(NakDedupAccept, RejectsBeyondMaxRepeats) {
    std::unordered_map<uint64_t, NakHashEntry> cache;
    ASSERT_TRUE(NakDeduplicator::should_accept_nak(cache, 0x3, 0));
    ASSERT_TRUE(NakDeduplicator::should_accept_nak(cache, 0x3, kSuppressMs));
    // After MAX_REPEATS (1) accepted re-emissions, further ones are rejected
    // even after the suppression window passes.
    EXPECT_FALSE(NakDeduplicator::should_accept_nak(cache, 0x3, kSuppressMs * 10));
}

TEST(NakDedupAccept, RejectsOnClockGoingBackwards) {
    std::unordered_map<uint64_t, NakHashEntry> cache;
    ASSERT_TRUE(NakDeduplicator::should_accept_nak(cache, 0x4, 5000));
    EXPECT_FALSE(NakDeduplicator::should_accept_nak(cache, 0x4, 1000));
}

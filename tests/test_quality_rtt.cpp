/*
    srtla - SRT transport proxy with link aggregation
    Copyright (C) 2026 CeraLive

    RTT / jitter weight-transition suite for the connection-quality evaluator
    (src/quality/quality_evaluator.cpp), driven by the Task 2 millisecond fake
    clock so every RTT-window and grace/throttle boundary is exercised with no
    real waits.

    ========================================================================
    WHAT THIS PINS, AND HOW
    ========================================================================
    The receiver scores RTT in two stages:

      1. QualityEvaluator::evaluate_group(group, current_time_sec)
         - reads the injected MsClock to size the bandwidth window,
         - when sender telemetry is fresh (has_valid_sender_telemetry), adds
           RTT error points via calculate_rtt_error_points():
               rtt_ms > RTT_THRESHOLD_CRITICAL (500)  -> +20
               rtt_ms > RTT_THRESHOLD_HIGH     (200)  -> +10
               rtt_ms > RTT_THRESHOLD_MODERATE (100)  -> +5
               stddev(rtt_history) > RTT_VARIANCE_THRESHOLD (50ms) -> +10 (flat)

      2. LoadBalancer::adjust_weights(group, current_time_sec)
         - maps the accumulated error_points to weight_percent:
               >= 40 -> WEIGHT_CRITICAL (10)
               >= 25 -> WEIGHT_POOR     (40)
               >= 15 -> WEIGHT_FAIR     (55)
               >= 10 -> WEIGHT_DEGRADED (70)
               >=  5 -> WEIGHT_EXCELLENT(85)
               else  -> WEIGHT_FULL     (100)

    weight_percent is the only observable asserted here; it is produced by the
    evaluator -> load-balancer pipeline above. Bandwidth and packet loss are
    held in the healthy zone (performance_ratio == 1.0, zero loss) in every
    helper so the RTT/jitter telemetry path is the sole error-point contributor.

    ========================================================================
    GREEN vs RED
    ========================================================================
    GREEN cases encode the CURRENT, correct behavior (characterization).
    RED cases assert the CORRECT behavior the code does NOT yet implement; each
    carries a RED marker comment naming the defect, tracked for plan Task 15.
    The production scoring code is intentionally untouched by this suite.

    Note on the steady-RTT mapping: the plan text guessed
    150ms->DEGRADED / 250ms->POOR / 600ms->CRITICAL. Tracing the arithmetic,
    the RTT base penalty saturates at +20 points, so steady RTT actually maps
    FULL / EXCELLENT / DEGRADED / FAIR (0/150/250/600ms) and never reaches
    POOR/CRITICAL. The GREEN cases below pin that real behavior; the gap to the
    plan's expectation is captured as the RED saturation case.
    ========================================================================
*/

#include <gtest/gtest.h>

#include <netinet/in.h>
#include <sys/socket.h>

#include <array>
#include <cstdint>
#include <cstring>
#include <memory>
#include <vector>

#include "connection/connection.h"
#include "connection/connection_group.h"
#include "quality/load_balancer.h"
#include "quality/quality_evaluator.h"
#include "receiver_config.h"

using srtla::ConnectionStats;
using srtla::RTT_HISTORY_SIZE;
using srtla::WEIGHT_CRITICAL;
using srtla::WEIGHT_DEGRADED;
using srtla::WEIGHT_EXCELLENT;
using srtla::WEIGHT_FAIR;
using srtla::WEIGHT_FULL;
using srtla::WEIGHT_POOR;
using srtla::CONN_QUALITY_EVAL_PERIOD;
using srtla::connection::Connection;
using srtla::connection::ConnectionGroup;
using srtla::connection::ConnectionGroupPtr;
using srtla::connection::ConnectionPtr;
using srtla::quality::LoadBalancer;
using srtla::quality::QualityEvaluator;

namespace {

using RttHistory = std::array<uint32_t, RTT_HISTORY_SIZE>;

struct sockaddr_storage make_addr(uint16_t port) {
    struct sockaddr_storage ss;
    std::memset(&ss, 0, sizeof(ss));
    auto *in = reinterpret_cast<struct sockaddr_in *>(&ss);
    in->sin_family = AF_INET;
    in->sin_port = htons(port);
    in->sin_addr.s_addr = htonl(0x7f000001); // 127.0.0.1
    return ss;
}

ConnectionGroupPtr make_group() {
    std::array<char, SRTLA_ID_LEN> id{};
    std::memcpy(id.data(), "quality-rtt-grp", 15);
    // created_at=0 with the large eval seconds below keeps the group well past
    // CONNECTION_GRACE_PERIOD, so grace/throttle never short-circuits a pass.
    return std::make_shared<ConnectionGroup>(id.data(), /*timestamp=*/0);
}

// A 5-deep RTT history with every slot at the same value (zero jitter).
RttHistory steady(uint32_t v) {
    RttHistory h{};
    h.fill(v);
    return h;
}

// A history holding four baseline samples and one trailing spike sample.
RttHistory with_spike(uint32_t base, uint32_t spike) {
    RttHistory h{};
    h.fill(base);
    h[RTT_HISTORY_SIZE - 1] = spike;
    return h;
}

// Logical wall-clock seconds for evaluate_group: far past CONNECTION_GRACE_PERIOD
// and the CONN_QUALITY_EVAL_PERIOD throttle so neither gate fires.
constexpr time_t kEvalSec = 1'000;
// Previous-evaluation millisecond stamp; the injected clock reports kBaseMs +
// a 1-second advance so the bandwidth window is a clean 1s.
constexpr uint64_t kBaseMs = 5'000'000;
constexpr uint64_t kWindowMs = 1'000;
// 250000 bytes over 1s == 2000 kbps (>= the 1000 kbps per-conn minimum) so
// performance_ratio == 1.0 and no bandwidth penalty is charged.
constexpr uint64_t kHealthyBytes = 250'000;
constexpr uint64_t kHealthyPackets = 1'000;

// Seed a connection's stats with healthy throughput + zero loss + fresh sender
// telemetry, so the only error-point contributor is the RTT/jitter path.
void seed_healthy_telemetry(ConnectionStats &s, time_t now_sec, uint64_t prev_ms,
                            uint32_t rtt_ms, const RttHistory &history,
                            int32_t window, int32_t in_flight) {
    s.sender_supports_extended_keepalives = true;
    s.last_keepalive = now_sec; // staleness 0 -> telemetry is fresh
    s.rtt_ms = rtt_ms;
    for (size_t i = 0; i < RTT_HISTORY_SIZE; ++i) {
        s.rtt_history[i] = history[i];
    }
    s.window = window;
    s.in_flight = in_flight;

    s.last_eval_time = prev_ms;
    s.last_bytes_received = 0;
    s.bytes_received = kHealthyBytes;
    s.last_packets_received = 0;
    s.packets_received = kHealthyPackets;
    s.last_packets_lost = 0;
    s.packets_lost = 0;
}

// Run one full evaluation (evaluator -> load balancer) for a single-connection
// group and return the resulting weight_percent. window>0 lets the 0ms-RTT case
// still present valid telemetry; in_flight stays 0 so window utilization is 0.
uint8_t weight_after_eval(uint32_t rtt_ms, const RttHistory &history,
                          int32_t window = 0, int32_t in_flight = 0) {
    auto group = make_group();
    auto conn = std::make_shared<Connection>(make_addr(50001), /*timestamp=*/0);
    seed_healthy_telemetry(conn->stats(), kEvalSec, kBaseMs, rtt_ms, history, window, in_flight);
    group->add_connection(conn);

    const uint64_t now_ms = kBaseMs + kWindowMs;
    QualityEvaluator evaluator([now_ms](uint64_t *ms) {
        *ms = now_ms;
        return 0;
    });
    evaluator.evaluate_group(group, kEvalSec);

    LoadBalancer lb;
    lb.adjust_weights(group, kEvalSec);
    return conn->stats().weight_percent;
}

// Stateful multi-round driver: each round delivers a fresh keepalive sample +
// one second of healthy traffic, advancing both the seconds clock (by
// CONN_QUALITY_EVAL_PERIOD, to clear the eval throttle) and the injected ms
// clock. Weight is sticky across rounds, exactly as in production.
class RttRoundRunner {
public:
    RttRoundRunner() {
        group_ = make_group();
        conn_ = std::make_shared<Connection>(make_addr(50007), /*timestamp=*/0);
        group_->add_connection(conn_);
    }

    uint8_t run_round(uint32_t rtt_ms, const RttHistory &history) {
        sec_ += CONN_QUALITY_EVAL_PERIOD; // each round clears the throttle window
        ms_ += kWindowMs;                 // 1s bandwidth window
        seed_healthy_telemetry(conn_->stats(), sec_, ms_ - kWindowMs, rtt_ms, history,
                               /*window=*/0, /*in_flight=*/0);

        const uint64_t now_ms = ms_;
        QualityEvaluator evaluator([now_ms](uint64_t *ms) {
            *ms = now_ms;
            return 0;
        });
        evaluator.evaluate_group(group_, sec_);
        lb_.adjust_weights(group_, sec_);
        return conn_->stats().weight_percent;
    }

private:
    ConnectionGroupPtr group_;
    ConnectionPtr conn_;
    LoadBalancer lb_;
    time_t sec_ = kEvalSec;   // start well past grace
    uint64_t ms_ = kBaseMs;
};

// Count tier transitions across a weight series (adjacent values that differ).
int count_tier_changes(const std::vector<uint8_t> &weights) {
    int changes = 0;
    for (size_t i = 1; i < weights.size(); ++i) {
        if (weights[i] != weights[i - 1]) {
            ++changes;
        }
    }
    return changes;
}

} // namespace

// ===========================================================================
// (a) Steady-RTT tier mapping -- GREEN: pins the current, correct behavior.
//     Zero jitter; the only signal is the RTT base penalty.
// ===========================================================================

// 0ms RTT on an otherwise-healthy link (telemetry valid via window>0) -> no
// penalty -> WEIGHT_FULL.
TEST(QualityRttSteadyTier, ZeroRttHealthyMapsToFull) {
    EXPECT_EQ(weight_after_eval(0, steady(0), /*window=*/1'000, /*in_flight=*/0), WEIGHT_FULL);
}

// 150ms (> MODERATE=100, < HIGH=200) -> +5 error points -> WEIGHT_EXCELLENT.
// (The plan text guessed DEGRADED; +5 maps to EXCELLENT under the load-balancer
// thresholds. GREEN encodes the actual mapping.)
TEST(QualityRttSteadyTier, Rtt150MapsToExcellent) {
    EXPECT_EQ(weight_after_eval(150, steady(150)), WEIGHT_EXCELLENT);
}

// 250ms (> HIGH=200, < CRITICAL=500) -> +10 -> WEIGHT_DEGRADED.
// (Plan text guessed POOR.)
TEST(QualityRttSteadyTier, Rtt250MapsToDegraded) {
    EXPECT_EQ(weight_after_eval(250, steady(250)), WEIGHT_DEGRADED);
}

// 600ms (> CRITICAL=500) -> +20 -> WEIGHT_FAIR.
// (Plan text guessed CRITICAL.)
TEST(QualityRttSteadyTier, Rtt600MapsToFair) {
    EXPECT_EQ(weight_after_eval(600, steady(600)), WEIGHT_FAIR);
}

// Severe, sustained RTT should drive weight into the POOR/CRITICAL band, but
// the RTT base penalty saturates at +20 points, so even a 2-second steady RTT
// only reaches WEIGHT_FAIR.
TEST(QualityRttSteadyTier, SevereSteadyRttShouldReachPoorOrWorse) {
    // RED: documents defect — RTT base penalties saturate at +20 points, so RTT above CRITICAL=500ms (here 2000ms steady) never drives weight below WEIGHT_FAIR; fix tracked in plan Task 15
    EXPECT_LE(weight_after_eval(2'000, steady(2'000)), WEIGHT_POOR);
}

// ===========================================================================
// (b) RTT variance / jitter around a 150ms mean.
//     rtt_ms is held at the mean (150ms -> base +5 -> EXCELLENT) so the test
//     isolates the jitter penalty. CORRECT behavior: jitter alone must not drop
//     a healthy, high-throughput, loss-free link below the tier the mean RTT
//     warrants (EXCELLENT). The flat +10 RTT_VARIANCE_THRESHOLD=50ms penalty
//     violates that for any stddev above 50ms.
// ===========================================================================

// GREEN boundary: ~35ms stddev ({100,125,150,175,200}) is below the 50ms
// threshold, so jitter is correctly ignored and weight stays EXCELLENT.
TEST(QualityRttJitter, JitterBelowThresholdStaysExcellent) {
    EXPECT_EQ(weight_after_eval(150, RttHistory{100, 125, 150, 175, 200}), WEIGHT_EXCELLENT);
}

// ~57ms stddev ({70,110,150,190,230}) -- normal cellular jitter, just above the
// 50ms threshold. The mean RTT (150ms) warrants EXCELLENT; jitter alone should
// not degrade it.
TEST(QualityRttJitter, ModerateJitterShouldNotDegradeHealthyLink) {
    // RED: documents defect — a healthy high-throughput loss-free link with only ~57ms RTT jitter is dropped a full tier (EXCELLENT->FAIR) by the flat +10 RTT_VARIANCE_THRESHOLD=50ms penalty; fix tracked in plan Task 15
    EXPECT_GE(weight_after_eval(150, RttHistory{70, 110, 150, 190, 230}), WEIGHT_EXCELLENT);
}

// ~99ms stddev ({10,80,150,220,290}). The variance penalty is binary, so this
// heavier jitter is penalized identically to the ~57ms case -- still no
// proportionality, still wrongly degrading a healthy link.
TEST(QualityRttJitter, HighJitterShouldNotDegradeHealthyLink) {
    // RED: documents defect — ~99ms jitter on an otherwise-healthy link is charged the same flat +10 as mild jitter, wrongly dropping EXCELLENT->FAIR with no proportionality to severity; fix tracked in plan Task 15
    EXPECT_GE(weight_after_eval(150, RttHistory{10, 80, 150, 220, 290}), WEIGHT_EXCELLENT);
}

// ~133ms stddev ({1,1,150,299,299}) -- the maximum spread representable around
// a 150ms mean with nonnegative RTT samples (the plan's "200ms stddev around
// 150ms mean" is not physically representable; it would require negative RTTs).
// Still a flat +10, still wrongly degraded.
TEST(QualityRttJitter, ExtremeJitterShouldNotDegradeHealthyLink) {
    // RED: documents defect — even maximal physical jitter (~133ms stddev) is charged the same flat +10 variance penalty, dropping a healthy link EXCELLENT->FAIR; the jitter penalty is binary, not proportional; fix tracked in plan Task 15
    EXPECT_GE(weight_after_eval(150, RttHistory{1, 1, 150, 299, 299}), WEIGHT_EXCELLENT);
}

// ===========================================================================
// (c) RTT_HISTORY_SIZE=5 estimator noise.
//     At a constant true RTT, statistically identical jitter batches must not
//     oscillate across weight tiers between consecutive evaluations.
// ===========================================================================

// GREEN control: a truly steady stream (zero jitter, every round identical)
// must be perfectly tier-stable across 10 rounds. Proves the harness yields
// stable output for stable input, isolating any oscillation to the jitter path.
TEST(QualityRttHistoryNoise, SteadyRttIsTierStableAcrossRounds) {
    RttRoundRunner r;
    std::vector<uint8_t> weights;
    for (int round = 0; round < 10; ++round) {
        weights.push_back(r.run_round(150, steady(150)));
    }
    EXPECT_LE(count_tier_changes(weights), 1);
}

// Constant true RTT (rtt_ms held at the median 150ms), with each round drawing
// a 5-sample jitter batch from the SAME ~50ms-jitter / 150ms-mean process.
// Two equally-valid realizations are alternated: batch A (~35ms realized
// stddev) and batch B (~57ms realized stddev). Both describe the identical
// underlying link; they differ only because a 5-sample window is too small to
// stabilize the variance estimate around the true value, so it straddles the
// 50ms decision boundary and the weight tier flips every round.
TEST(QualityRttHistoryNoise, ConstantTrueRttMustNotOscillateAcrossTiers) {
    const RttHistory batch_a{100, 125, 150, 175, 200}; // realized stddev ~35ms
    const RttHistory batch_b{70, 110, 150, 190, 230};  // realized stddev ~57ms

    RttRoundRunner r;
    std::vector<uint8_t> weights;
    for (int round = 0; round < 10; ++round) {
        weights.push_back(r.run_round(150, (round % 2 == 0) ? batch_a : batch_b));
    }

    // RED: documents defect — the RTT_HISTORY_SIZE=5 variance estimator straddles the 50ms threshold for statistically identical jitter batches, oscillating weight EXCELLENT<->FAIR at constant true RTT; fix tracked in plan Task 15
    EXPECT_LE(count_tier_changes(weights), 1);
}

// ===========================================================================
// (d) Spike recovery -- GREEN: recovery must actually happen.
//     100ms -> 500ms spike -> 100ms. N = 1 evaluation period: at ~1 keepalive/s
//     a full CONN_QUALITY_EVAL_PERIOD (5s) delivers RTT_HISTORY_SIZE (5) fresh
//     samples, completely flushing the spike from the variance window, so
//     weight returns to FULL within one period after the true RTT normalizes.
// ===========================================================================
TEST(QualityRttSpikeRecovery, WeightRecoversWithinOnePeriodAfterSpike) {
    RttRoundRunner r;

    // Baseline: steady 100ms (== MODERATE threshold; strict '>' => no penalty) -> FULL.
    EXPECT_EQ(r.run_round(100, steady(100)), WEIGHT_FULL);

    // Spike: latest sample 500ms with the spike in the history -> weight degrades.
    const uint8_t spiked = r.run_round(500, with_spike(100, 500));
    EXPECT_LT(spiked, WEIGHT_FULL) << "RTT spike must engage a penalty";

    // Recovery: true RTT back to 100ms. One full period of fresh samples flushes
    // the spike -> weight back to FULL (N=1), then stays recovered.
    EXPECT_EQ(r.run_round(100, steady(100)), WEIGHT_FULL) << "must recover within 1 eval period";
    EXPECT_EQ(r.run_round(100, steady(100)), WEIGHT_FULL) << "must stay recovered";
}

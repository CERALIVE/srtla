/*
    srtla - SRT transport proxy with link aggregation
    Copyright (C) 2026 CeraLive

    Millisecond-resolution fake clock for the latency test suites (Tasks 8/9).

    ========================================================================
    CAPABILITY VERDICT (fake-clock / quality-evaluator time injection)
    ========================================================================
    Two time seams drive connection-quality evaluation in srtla_rec:

      (A) the SECONDS seam: QualityEvaluator::evaluate_group(group, current_time)
          takes current_time (time_t) as a parameter. It gates the
          CONN_QUALITY_EVAL_PERIOD throttle, the CONNECTION_GRACE_PERIOD
          window, RTT-staleness (KEEPALIVE_STALENESS_THRESHOLD), and
          has_valid_sender_telemetry(). RTT *samples* themselves are plain
          ConnectionStats fields a test sets directly.

      (B) the MILLISECONDS seam: the bandwidth/eval window inside
          evaluate_group reads a monotonic ms timestamp to compute
          time_diff_ms = current_ms - stats.last_eval_time, which drives the
          measured throughput and is then written back to last_eval_time.

                              | ms-resolution | evaluator injectable
      ----------------------- | ------------- | --------------------
      BEFORE this change      |      NO       |   PARTIAL (seconds only)
      AFTER this change       |     YES       |   YES (seconds + ms)

    BEFORE: seam (A) was injectable (a function parameter), but seam (B) was
    a hardcoded get_ms() wall-clock read. A test could not advance the ms
    clock in 1ms / 50ms / 999ms steps; the bandwidth window reflected real
    elapsed time only.

    AFTER: QualityEvaluator owns a MsClock (std::function<int(uint64_t*)>,
    same 0=ok / non-zero=fail contract as get_ms). The default constructor
    threads the real get_ms through unchanged (production path byte-identical);
    the new explicit(MsClock) constructor lets a test inject a deterministic
    ms clock. No global, no real sleeps.

    These tests prove seam (B): a fixed bytes delta evaluated across a chosen
    current_ms yields a bandwidth output that is a closed-form function of the
    injected millisecond advance, so 1ms / 50ms / 999ms steps are each
    observable in code under test (group->total_target_bandwidth()), and a 1ms
    vs 2ms step is distinguishable (true millisecond, not coarser, resolution).
    ========================================================================
*/

#include <gtest/gtest.h>

#include <netinet/in.h>
#include <sys/socket.h>

#include <array>
#include <cstring>
#include <memory>

#include "connection/connection.h"
#include "connection/connection_group.h"
#include "quality/quality_evaluator.h"
#include "receiver_config.h"

using srtla::CONN_QUALITY_EVAL_PERIOD;
using srtla::connection::Connection;
using srtla::connection::ConnectionGroup;
using srtla::connection::ConnectionGroupPtr;
using srtla::connection::ConnectionPtr;
using srtla::quality::QualityEvaluator;

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

ConnectionGroupPtr make_group() {
    std::array<char, SRTLA_ID_LEN> id{};
    std::memcpy(id.data(), "fake-clock-group", 16);
    // created_at=0: with the large eval current_time used below the group is
    // well past CONNECTION_GRACE_PERIOD, so penalty/grace gating never trips.
    return std::make_shared<ConnectionGroup>(id.data(), /*timestamp=*/0);
}

// Logical wall-clock seconds passed to evaluate_group. Far above the throttle
// and grace windows so neither short-circuits the bandwidth pass.
constexpr time_t kEvalSeconds = 1'000;

// Baseline millisecond timestamp the connection's previous evaluation landed on.
constexpr uint64_t kBaseMs = 5'000'000;

// Build a single-connection group primed with a known bytes delta and a
// previous-evaluation timestamp of kBaseMs, then run one evaluation whose
// injected ms clock reports (kBaseMs + advance_ms). The returned
// total_target_bandwidth is the receiver's measured throughput in bytes/sec:
//   bytes_delta / (advance_ms / 1000).
uint64_t bandwidth_for_advance(uint64_t bytes_delta, uint64_t advance_ms) {
    auto group = make_group();
    auto conn = std::make_shared<Connection>(make_addr(50001), /*timestamp=*/0);
    conn->stats().last_eval_time = kBaseMs;
    conn->stats().last_bytes_received = 0;
    conn->stats().bytes_received = bytes_delta;
    group->add_connection(conn);

    const uint64_t now_ms = kBaseMs + advance_ms;
    QualityEvaluator evaluator([now_ms](uint64_t *ms) {
        *ms = now_ms;
        return 0;
    });
    evaluator.evaluate_group(group, kEvalSeconds);
    return group->total_target_bandwidth();
}

} // namespace

// 1ms advance: 999000 bytes over 1ms reads as 999000 * 1000 bytes/sec.
TEST(FakeClock, AdvanceOneMillisecondObservable) {
    EXPECT_EQ(bandwidth_for_advance(999'000, 1), 999'000'000ull);
}

// 50ms advance: same bytes over 50ms reads as 999000 / 0.05 bytes/sec.
TEST(FakeClock, AdvanceFiftyMillisecondsObservable) {
    EXPECT_EQ(bandwidth_for_advance(999'000, 50), 19'980'000ull);
}

// 999ms advance: same bytes over 999ms reads as exactly 1,000,000 bytes/sec.
TEST(FakeClock, AdvanceNineNineNineMillisecondsObservable) {
    EXPECT_EQ(bandwidth_for_advance(999'000, 999), 1'000'000ull);
}

// The three advances must yield three distinct, strictly-decreasing throughputs
// for a fixed bytes delta: the smaller the millisecond window, the higher the
// measured rate. Proves the injected ms value flows through, not a constant.
TEST(FakeClock, DistinctAdvancesProduceDistinctBandwidth) {
    const uint64_t one = bandwidth_for_advance(999'000, 1);
    const uint64_t fifty = bandwidth_for_advance(999'000, 50);
    const uint64_t nine = bandwidth_for_advance(999'000, 999);
    EXPECT_GT(one, fifty);
    EXPECT_GT(fifty, nine);
}

// True millisecond granularity: a single-millisecond difference (1ms vs 2ms)
// is observable, so the seam is not quantized to a coarser unit.
TEST(FakeClock, OneMillisecondGranularityIsResolvable) {
    EXPECT_NE(bandwidth_for_advance(1'000'000, 1), bandwidth_for_advance(1'000'000, 2));
}

// The default-constructed evaluator keeps the production get_ms path: it must
// still drive the same bandwidth window. With last_eval_time seeded to 1ms the
// real monotonic clock is far ahead, so the evaluation runs and stamps
// last_eval_time with that real (large) timestamp — proving the default clock
// was invoked without any injected value and with no real sleep.
TEST(FakeClock, DefaultConstructorUsesProductionClock) {
    auto group = make_group();
    auto conn = std::make_shared<Connection>(make_addr(50002), /*timestamp=*/0);
    conn->stats().last_eval_time = 1;  // ~epoch of the monotonic ms clock
    conn->stats().last_bytes_received = 0;
    conn->stats().bytes_received = 1'000;
    group->add_connection(conn);

    QualityEvaluator evaluator;  // production clock
    evaluator.evaluate_group(group, kEvalSeconds);

    EXPECT_GT(conn->stats().last_eval_time, 1u)
        << "default clock must advance last_eval_time to the real monotonic ms";
}

// A null injected clock falls back to the production default rather than
// storing an empty std::function (which would throw on call).
TEST(FakeClock, NullInjectedClockFallsBackToProduction) {
    auto group = make_group();
    auto conn = std::make_shared<Connection>(make_addr(50003), /*timestamp=*/0);
    conn->stats().last_eval_time = 1;
    conn->stats().bytes_received = 1'000;
    group->add_connection(conn);

    QualityEvaluator evaluator(QualityEvaluator::MsClock{});  // null clock
    EXPECT_NO_THROW(evaluator.evaluate_group(group, kEvalSeconds));
    EXPECT_GT(conn->stats().last_eval_time, 1u);
}

#pragma once

#include <cstdint>
#include <functional>

#include "metrics_collector.h"
#include "../connection/connection_group.h"

namespace srtla::quality {

struct QualityMetrics {
    double bandwidth_kbits_per_sec = 0.0;
    double packet_loss_ratio = 0.0;
    uint64_t packets_diff = 0;
    uint32_t error_points = 0;
};

class QualityEvaluator {
public:
    // Millisecond clock seam used for the bandwidth/eval window. Mirrors the
    // common.h get_ms contract: returns 0 on success and writes the current
    // monotonic millisecond timestamp into *ms; a non-zero return signals
    // failure. Production threads the real get_ms through here unchanged; the
    // latency test suites (Tasks 8/9) inject a fake clock so RTT-window and
    // timeout boundaries can be exercised at millisecond resolution with no
    // real waits. Not a global — each evaluator owns its clock.
    using MsClock = std::function<int(uint64_t *)>;

    // Default: production monotonic clock (wraps get_ms, byte-identical path).
    QualityEvaluator();
    // Inject a millisecond clock for deterministic tests. A null clock falls
    // back to the production default.
    explicit QualityEvaluator(MsClock ms_clock);

    void evaluate_group(connection::ConnectionGroupPtr group,
                        time_t current_time);

private:
    void evaluate_connection(connection::ConnectionGroupPtr group,
                              const connection::ConnectionPtr &conn,
                              double bandwidth_kbits_per_sec,
                              double packet_loss_ratio,
                              double median_kbits_per_sec,
                              double min_expected_kbits_per_sec,
                              bool is_poor_connection);
    
    // Helper functions for RTT-based quality assessment (Connection Info algorithm)
    uint32_t calculate_rtt_error_points(const ConnectionStats &stats, time_t current_time);
    double calculate_rtt_variance(const ConnectionStats &stats);
    double calculate_rtt_mean(const ConnectionStats &stats);
    
    // Helper functions for NAK rate analysis (Connection Info algorithm)
    uint32_t calculate_nak_error_points(ConnectionStats &stats, uint64_t packets_diff);
    
    // Helper functions for window utilization (Connection Info algorithm)
    uint32_t calculate_window_error_points(const ConnectionStats &stats);
    
    // Helper function for bitrate validation (Connection Info algorithm)
    void validate_bitrate(const ConnectionStats &stats,
                         double receiver_bitrate_bps,
                         const struct sockaddr_storage *addr);
    
    // Legacy algorithm (without connection info)
    void evaluate_connection_legacy(connection::ConnectionPtr conn,
                                    double bandwidth_kbits_per_sec,
                                    double packet_loss_ratio,
                                    double performance_ratio,
                                    time_t current_time);

    MsClock ms_clock_;
};

} // namespace srtla::quality

# Google Test via FetchContent
include(FetchContent)
FetchContent_Declare(
  googletest
  GIT_REPOSITORY https://github.com/google/googletest.git
  GIT_TAG        v1.15.2
)
# For Windows: Prevent overriding the parent project's compiler/linker settings
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(googletest)

include(GoogleTest)

# Helper: create a GTest executable with consistent settings.
function(srtla_add_test name)
  add_executable(${name} ${ARGN})
  target_link_libraries(${name} PRIVATE GTest::gtest_main)
  target_include_directories(${name} PRIVATE ${CMAKE_SOURCE_DIR}/src)
  target_compile_features(${name} PRIVATE cxx_std_17)
  target_compile_options(${name} PRIVATE -Wall -Wextra)
  gtest_discover_tests(${name})
endfunction()

# C-helpers test (parsing, header inspection, packet shape).
srtla_add_test(test_common test_common.cpp)
target_link_libraries(test_common PRIVATE common_obj)

# Sender decision-logic test: conn_is_timed_out / housekeeping_action
# (906ac05 bootstrap regression guard) and the update_conns SIGHUP reload guard
# (count_parseable_source_ips / reload_should_apply). Links common_obj for parse_ip.
srtla_add_test(test_sender_bootstrap test_sender_bootstrap.cpp)
target_link_libraries(test_sender_bootstrap PRIVATE common_obj)

# NAK deduplication characterization (pure logic).
srtla_add_test(test_nak_dedup test_nak_dedup.cpp)
target_link_libraries(test_nak_dedup PRIVATE receiver_core_obj common_obj)

# LoadBalancer weight-mapping characterization.
srtla_add_test(test_load_balancer test_load_balancer.cpp)
target_link_libraries(test_load_balancer PRIVATE receiver_core_obj common_obj)

# Post-merge SRTLA ACK behavior characterization (no time-based throttling).
# The pre-merge version of this file asserted the inverse; the diff
# between the two versions is the canonical record of the behavior change.
srtla_add_test(test_srtla_handler_ack test_srtla_handler_ack.cpp)
target_link_libraries(test_srtla_handler_ack PRIVATE receiver_core_obj common_obj)

# pad_sendto coverage: padding to 32 bytes for small frames, passthrough otherwise.
srtla_add_test(test_pad_sendto test_pad_sendto.cpp)

# Broadcast ACK/NAK predicate coverage.
# is_srt_ack / is_srt_nak drive SRTHandler::handle_srt_data's broadcast
# branch; HANDSHAKE must NOT match (after upstream commit 2de6dbb).
srtla_add_test(test_broadcast_ack test_broadcast_ack.cpp)
target_link_libraries(test_broadcast_ack PRIVATE common_obj)

# --- Hardening reproducers (Task 14): races, exhaustion, timeouts ----------
# These drive the real receiver registration path over a loopback UDP socket
# (handler_harness.h) and the cleanup reaper through its injected-clock seam.

# Family 1 + 5: REG3/NGP race and concurrent multi-interface registration.
srtla_add_test(test_reg_race test_reg_race.cpp)
target_link_libraries(test_reg_race PRIVATE receiver_core_obj common_obj)

# Family 2: MAX_GROUPS exhaustion (clean REG_ERR, retry-after-dereg, RSS).
srtla_add_test(test_group_limits test_group_limits.cpp)
target_link_libraries(test_group_limits PRIVATE receiver_core_obj common_obj)

# Family 6 (Task 1, RED): ghost-group eviction DoS hardening (upstream 7855012,
# pre-cherry-pick). Drives the real registration path (handler_harness.h) and the
# cleanup reaper (injected clock) to assert behavior absent on current main:
# never-streamed ghosts reaped at PENDING_GROUP_TIMEOUT, oldest-ghost eviction
# admits a registration under table pressure, and groups that forwarded real SRT
# data are promoted (neither reaped early nor evicted). RED until the fix lands.
# Defined inline (like test_registration_handshake) so a "ghost_group." TEST_PREFIX
# makes `ctest -R ghost_group` select exactly this suite. Links like test_group_limits.
add_executable(test_ghost_group_eviction test_ghost_group_eviction.cpp)
target_link_libraries(test_ghost_group_eviction
  PRIVATE GTest::gtest_main receiver_core_obj common_obj)
target_include_directories(test_ghost_group_eviction PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_compile_features(test_ghost_group_eviction PRIVATE cxx_std_17)
target_compile_options(test_ghost_group_eviction PRIVATE -Wall -Wextra)
gtest_discover_tests(test_ghost_group_eviction TEST_PREFIX "ghost_group.")

# Family 3: timeout / cleanup via ConnectionRegistry::cleanup_inactive(ts, cb).
srtla_add_test(test_timeout_cleanup test_timeout_cleanup.cpp)
target_link_libraries(test_timeout_cleanup PRIVATE receiver_core_obj common_obj)

# Millisecond-resolution fake clock (PR2 infra for the latency suites, Tasks 8/9):
# proves QualityEvaluator's injected MsClock drives the bandwidth/eval window at
# 1ms / 50ms / 999ms resolution and that the default ctor keeps the production
# get_ms path. Inline registration with a "fake_clock." TEST_PREFIX so
# `ctest -R fake_clock` selects exactly this suite. Links like test_timeout_cleanup.
add_executable(test_fake_clock test_fake_clock.cpp)
target_link_libraries(test_fake_clock
  PRIVATE GTest::gtest_main receiver_core_obj common_obj)
target_include_directories(test_fake_clock PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_compile_features(test_fake_clock PRIVATE cxx_std_17)
target_compile_options(test_fake_clock PRIVATE -Wall -Wextra)
gtest_discover_tests(test_fake_clock TEST_PREFIX "fake_clock.")

# Timeout boundary contracts under high-RTT / jitter (PR2, Task 9): receiver
# reaper (CONN_TIMEOUT boundary, keepalive-jitter survival, recovery-window
# throttle defect) via cleanup_inactive()'s injected clock, and the sender
# watchdog (boundary, benign-jitter survival, false-down defect, dead-link
# detection) via the pure conn_is_timed_out() predicate — no real sleeps. Two
# cases are RED (document defects fixed in Tasks 14/15). Inline registration
# with a "timeout_boundaries." TEST_PREFIX so `ctest -R timeout_boundaries`
# selects exactly this suite. Links like test_timeout_cleanup.
add_executable(test_timeout_boundaries test_timeout_boundaries.cpp)
target_link_libraries(test_timeout_boundaries
  PRIVATE GTest::gtest_main receiver_core_obj common_obj)
target_include_directories(test_timeout_boundaries PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_compile_features(test_timeout_boundaries PRIVATE cxx_std_17)
target_compile_options(test_timeout_boundaries PRIVATE -Wall -Wextra)
gtest_discover_tests(test_timeout_boundaries TEST_PREFIX "timeout_boundaries.")

# Service-primitive identity hooks (Task 16): GroupIdentity snapshot + register/
# teardown extension points fire at the right lifecycle moments with correct
# data; the default (no-hook) path stays byte-identical and the stream-id
# resolver's return is never consulted (single SRT target preserved).
srtla_add_test(test_identity_hooks test_identity_hooks.cpp)
target_link_libraries(test_identity_hooks PRIVATE receiver_core_obj common_obj)

# Extended-keepalive parsing + sender-telemetry activation/fallback semantics.
# Pins parse_keepalive_conn_info() and the supports_extended_keepalives /
# has_valid_sender_telemetry split (including the zero-value EC5 edge).
srtla_add_test(test_extended_keepalive test_extended_keepalive.cpp)
target_link_libraries(test_extended_keepalive PRIVATE common_obj)

# REG1/REG2/REG3 handshake state-machine characterization.
# Drives SRTLAHandler::process_packets over a real loopback UDP seam to
# freeze register_group / register_connection contracts (REG2/REG3 replies,
# REG_ERR / REG_NGP error paths, idempotency, multi-link bonding).
# Defined inline (not via srtla_add_test) so a "registration." TEST_PREFIX
# can be attached, keeping `ctest -R registration` selective for this suite.
add_executable(test_registration_handshake test_registration_handshake.cpp)
target_link_libraries(test_registration_handshake
  PRIVATE GTest::gtest_main receiver_core_obj common_obj)
target_include_directories(test_registration_handshake PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_compile_features(test_registration_handshake PRIVATE cxx_std_17)
target_compile_options(test_registration_handshake PRIVATE -Wall -Wextra)
gtest_discover_tests(test_registration_handshake TEST_PREFIX "registration.")

# Sender telemetry serializer + atomic stats-file publish (Task 18, ADR-001).
# Pins src/sender_telemetry.h: golden-file schema conformance, the mandated
# bytes->bits bitrate conversion, empty state, update cadence, and the rename(2)
# atomicity guarantee under a concurrent reader. Header-only (no srtla object
# libs); Threads backs the atomicity test's reader/writer.
srtla_add_test(test_telemetry_emit test_telemetry_emit.cpp)
find_package(Threads REQUIRED)
target_link_libraries(test_telemetry_emit PRIVATE Threads::Threads)
target_compile_definitions(test_telemetry_emit PRIVATE
  TELEMETRY_GOLDEN_DIR="${CMAKE_CURRENT_SOURCE_DIR}/golden")

# Per-IP SRT auth-failure throttle (upstream 39e324a) + is_srt_shutdown classifier.
# Pure time-as-parameter logic: no clock injection, no real waits. Links
# receiver_core_obj (AuthRateLimiter) and common_obj (is_srt_shutdown).
# Inline registration with a "auth_rate_limiter." TEST_PREFIX so
# `ctest -R auth_rate_limiter` selects exactly this suite (ghost_group idiom).
add_executable(test_auth_rate_limiter test_auth_rate_limiter.cpp)
target_link_libraries(test_auth_rate_limiter
  PRIVATE GTest::gtest_main receiver_core_obj common_obj)
target_include_directories(test_auth_rate_limiter PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_compile_features(test_auth_rate_limiter PRIVATE cxx_std_17)
target_compile_options(test_auth_rate_limiter PRIVATE -Wall -Wextra)
gtest_discover_tests(test_auth_rate_limiter TEST_PREFIX "auth_rate_limiter.")

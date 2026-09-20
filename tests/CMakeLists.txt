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

# NAK deduplication characterization (pure logic).
srtla_add_test(test_nak_dedup test_nak_dedup.cpp)
target_link_libraries(test_nak_dedup PRIVATE rec_obj common_obj)

# LoadBalancer weight-mapping characterization.
srtla_add_test(test_load_balancer test_load_balancer.cpp)
target_link_libraries(test_load_balancer PRIVATE rec_obj common_obj)

# Post-merge SRTLA ACK behavior characterization (no time-based throttling).
srtla_add_test(test_srtla_handler_ack test_srtla_handler_ack.cpp)
target_link_libraries(test_srtla_handler_ack PRIVATE rec_obj common_obj)

# pad_sendto coverage: padding to 32 bytes for small frames, passthrough otherwise.
srtla_add_test(test_pad_sendto test_pad_sendto.cpp)

# Broadcast ACK/NAK predicate coverage.
# is_srt_ack / is_srt_nak drive SRTHandler::handle_srt_data's broadcast
# branch; HANDSHAKE must NOT match (after upstream commit 2de6dbb).
srtla_add_test(test_broadcast_ack test_broadcast_ack.cpp)
target_link_libraries(test_broadcast_ack PRIVATE common_obj)

# --- Hardening reproducers: races, exhaustion, timeouts -------------------
# These drive the real receiver registration path over a loopback UDP socket
# (handler_harness.h) and the cleanup reaper.

# REG3/NGP race and concurrent multi-interface registration.
srtla_add_test(test_reg_race test_reg_race.cpp)
target_link_libraries(test_reg_race PRIVATE rec_obj common_obj)

# MAX_GROUPS exhaustion (clean REG_ERR, retry-after-dereg, RSS).
srtla_add_test(test_group_limits test_group_limits.cpp)
target_link_libraries(test_group_limits PRIVATE rec_obj common_obj)

# Ghost-group eviction DoS hardening (upstream 7855012). Drives the real
# registration path (handler_harness.h) and the cleanup reaper to assert
# never-streamed ghosts are reaped at PENDING_GROUP_TIMEOUT, oldest-ghost
# eviction admits a registration under table pressure, and groups that
# forwarded real SRT data are promoted. Defined inline so a "ghost_group."
# TEST_PREFIX makes `ctest -R ghost_group` select exactly this suite.
add_executable(test_ghost_group_eviction test_ghost_group_eviction.cpp)
target_link_libraries(test_ghost_group_eviction
  PRIVATE GTest::gtest_main rec_obj common_obj)
target_include_directories(test_ghost_group_eviction PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_compile_features(test_ghost_group_eviction PRIVATE cxx_std_17)
target_compile_options(test_ghost_group_eviction PRIVATE -Wall -Wextra)
gtest_discover_tests(test_ghost_group_eviction TEST_PREFIX "ghost_group.")

# Timeout / cleanup via ConnectionRegistry::cleanup_inactive().
srtla_add_test(test_timeout_cleanup test_timeout_cleanup.cpp)
target_link_libraries(test_timeout_cleanup PRIVATE rec_obj common_obj)

# Extended-keepalive parsing semantics: pins parse_keepalive_conn_info() and
# the supports_extended_keepalives split (including the zero-value edge).
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
  PRIVATE GTest::gtest_main rec_obj common_obj)
target_include_directories(test_registration_handshake PRIVATE ${CMAKE_SOURCE_DIR}/src)
target_compile_features(test_registration_handshake PRIVATE cxx_std_17)
target_compile_options(test_registration_handshake PRIVATE -Wall -Wextra)
gtest_discover_tests(test_registration_handshake TEST_PREFIX "registration.")

# NOTE — tests DROPPED on the upstream base because they only compile against
# fork-only seams in src/, and src/ stays byte-identical to upstream b8359bc:
#   test_auth_rate_limiter  -> AuthRateLimiter::tracked_entry_count()
#   test_fake_clock         -> QualityEvaluator MsClock injection ctor
#   test_quality_rtt        -> QualityEvaluator MsClock injection ctor
#   test_identity_hooks     -> ConnectionGroup GroupIdentity / external_id hooks
#   test_sender_bootstrap   -> src/sender_logic.h
#   test_timeout_boundaries -> src/sender_logic.h
#   test_telemetry_emit     -> src/sender_telemetry.h

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

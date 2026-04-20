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

# Pre-merge SRTLA ACK-throttling characterization.
# This test asserts the current (CERALIVE) throttling behavior. Once the
# upstream merge lands (which removes ACK throttling), this file is rewritten
# in T3d to assert the inverse, so the diff is self-documenting.
srtla_add_test(test_srtla_handler_ack test_srtla_handler_ack.cpp)
target_link_libraries(test_srtla_handler_ack PRIVATE receiver_core_obj common_obj)

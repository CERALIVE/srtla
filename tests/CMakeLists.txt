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

# Test executable for common utilities
add_executable(test_common
  test_common.cpp
)

target_link_libraries(test_common PRIVATE
  common_obj
  GTest::gtest_main
)

target_include_directories(test_common PRIVATE
  ${CMAKE_SOURCE_DIR}/src
)

target_compile_features(test_common PRIVATE cxx_std_17)

# Register tests with CTest
gtest_discover_tests(test_common)

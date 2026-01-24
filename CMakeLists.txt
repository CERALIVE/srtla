cmake_minimum_required(VERSION 3.16)
project(srtla VERSION 1.0.0 LANGUAGES C CXX)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_LIST_DIR}/cmake/Modules")

# Options
option(SRTLA_BUILD_TESTS "Build tests" ON)
option(SRTLA_ENABLE_CLANG_TIDY "Enable clang-tidy static analysis" OFF)

include(FetchContent)

# Fetch and build spdlog statically
FetchContent_Declare(
    spdlog
    GIT_REPOSITORY https://github.com/irlserver/spdlog.git
    GIT_TAG 1.9.2
)
set(SPDLOG_BUILD_SHARED OFF CACHE BOOL "Build spdlog as shared library")
set(SPDLOG_BUILD_EXAMPLE OFF CACHE BOOL "Build spdlog examples")
FetchContent_MakeAvailable(spdlog)

# Clang-tidy integration
if(SRTLA_ENABLE_CLANG_TIDY)
  find_program(CLANG_TIDY_EXE NAMES clang-tidy)
  if(CLANG_TIDY_EXE)
    message(STATUS "clang-tidy found: ${CLANG_TIDY_EXE}")
    set(CMAKE_C_CLANG_TIDY "${CLANG_TIDY_EXE}")
    set(CMAKE_CXX_CLANG_TIDY "${CLANG_TIDY_EXE}")
  else()
    message(WARNING "clang-tidy requested but not found")
  endif()
endif()

add_library(common_obj OBJECT
    src/common.c
    src/common.h)

add_executable(srtla_rec
    src/receiver_main.cpp
    src/connection/connection.cpp
    src/connection/connection_group.cpp
    src/connection/connection_registry.cpp
    src/quality/metrics_collector.cpp
    src/quality/quality_evaluator.cpp
    src/quality/load_balancer.cpp
    src/protocol/srtla_handler.cpp
    src/protocol/srt_handler.cpp
    src/utils/network_utils.cpp
    src/utils/nak_dedup.cpp)

target_include_directories(srtla_rec PRIVATE
    "deps/argparse/include"
    "${CMAKE_CURRENT_SOURCE_DIR}/src")

target_link_libraries(srtla_rec PRIVATE
    common_obj
    spdlog::spdlog
)
target_compile_features(srtla_rec PRIVATE cxx_std_17)
target_compile_options(srtla_rec PRIVATE -Wall -Wextra)
target_compile_definitions(srtla_rec PUBLIC VERSION="${CMAKE_PROJECT_VERSION}")

add_executable(srtla_send
    src/sender.cpp
    src/sender.h)

target_include_directories(srtla_send PRIVATE
    "deps/argparse/include")
target_link_libraries(srtla_send PRIVATE
    common_obj
    spdlog::spdlog
)
target_compile_features(srtla_send PRIVATE cxx_std_17)
target_compile_options(srtla_send PRIVATE -Wall -Wextra)
target_compile_definitions(srtla_send PUBLIC VERSION="${CMAKE_PROJECT_VERSION}")

if(NOT CMAKE_CONFIGURATION_TYPES AND NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "Build type" FORCE)
endif()
install(TARGETS srtla_rec srtla_send RUNTIME DESTINATION bin)

# Testing
if(SRTLA_BUILD_TESTS)
  enable_testing()
  if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/tests/CMakeLists.txt")
    add_subdirectory(tests)
  endif()
endif()

# Custom lint target for manual clang-tidy runs
add_custom_target(lint
  COMMAND ${CMAKE_COMMAND} -E echo "Running clang-tidy on C files..."
  COMMAND clang-tidy
    ${CMAKE_CURRENT_SOURCE_DIR}/src/common.c
    --
    -I${CMAKE_CURRENT_SOURCE_DIR}/src
    -std=c11
    -D_GNU_SOURCE
  COMMAND ${CMAKE_COMMAND} -E echo "Running clang-tidy on C++ files..."
  COMMAND clang-tidy
    ${CMAKE_CURRENT_SOURCE_DIR}/src/receiver_main.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/src/sender.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/src/connection/connection.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/src/connection/connection_group.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/src/connection/connection_registry.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/src/quality/metrics_collector.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/src/quality/quality_evaluator.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/src/quality/load_balancer.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/src/protocol/srtla_handler.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/src/protocol/srt_handler.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/src/utils/network_utils.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/src/utils/nak_dedup.cpp
    --
    -I${CMAKE_CURRENT_SOURCE_DIR}/deps/argparse/include
    -I${CMAKE_CURRENT_SOURCE_DIR}/src
    -std=c++17
    -D_GNU_SOURCE
    '-DVERSION="${CMAKE_PROJECT_VERSION}"'
  WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
  COMMENT "Running clang-tidy static analysis..."
)

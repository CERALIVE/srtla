cmake_minimum_required(VERSION 3.16)
project(srtla VERSION 1.0.0 LANGUAGES C CXX)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_LIST_DIR}/cmake/Modules")

# Options
option(SRTLA_BUILD_TESTS "Build tests" ON)
option(SRTLA_ENABLE_CLANG_TIDY "Enable clang-tidy static analysis" OFF)

find_package(spdlog REQUIRED)

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
    src/receiver.cpp
    src/receiver.h)

target_include_directories(srtla_rec PRIVATE
    "deps/argparse/include")
target_link_libraries(srtla_rec PRIVATE
    common_obj
    spdlog::spdlog
    -Wl,-rpath,/usr/local/lib
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
    -Wl,-rpath,/usr/local/lib
)
target_compile_features(srtla_send PRIVATE cxx_std_17)
target_compile_options(srtla_send PRIVATE -Wall -Wextra)
target_compile_definitions(srtla_send PUBLIC VERSION="${CMAKE_PROJECT_VERSION}")

set(CMAKE_BUILD_TYPE RelWithDebInfo)
install(TARGETS srtla_rec srtla_send RUNTIME DESTINATION bin)

# Testing
if(SRTLA_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
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
    ${CMAKE_CURRENT_SOURCE_DIR}/src/receiver.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/src/sender.cpp
    --
    -I${CMAKE_CURRENT_SOURCE_DIR}/deps/argparse/include
    -I${CMAKE_CURRENT_SOURCE_DIR}/src
    -std=c++17
    -D_GNU_SOURCE
    '-DVERSION="${CMAKE_PROJECT_VERSION}"'
  WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
  COMMENT "Running clang-tidy static analysis..."
)

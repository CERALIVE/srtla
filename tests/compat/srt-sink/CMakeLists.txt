# srt-sink — mock SRT endpoint for the compatibility harness.
#
# Links the system libsrt (the same transport srtla speaks to at runtime); srtla
# itself is a UDP proxy and does not otherwise link libsrt, so the dependency is
# resolved here, gated behind BUILD_COMPAT_TESTS, and never affects the default
# srtla_send / srtla_rec build.

find_package(PkgConfig QUIET)
if(PkgConfig_FOUND)
  pkg_check_modules(SRT IMPORTED_TARGET srt)
endif()

add_executable(srt-sink main.cpp)
target_compile_features(srt-sink PRIVATE cxx_std_17)
target_compile_options(srt-sink PRIVATE -Wall -Wextra)

if(TARGET PkgConfig::SRT)
  target_link_libraries(srt-sink PRIVATE PkgConfig::SRT)
else()
  # Fall back to a plain library/header search when pkg-config is unavailable.
  find_path(SRT_INCLUDE_DIR NAMES srt/srt.h)
  find_library(SRT_LIBRARY NAMES srt)
  if(NOT SRT_INCLUDE_DIR OR NOT SRT_LIBRARY)
    message(FATAL_ERROR
      "BUILD_COMPAT_TESTS=ON but libsrt was not found. "
      "Install libsrt (e.g. libsrt-openssl-dev / libsrt-gnutls-dev) and retry.")
  endif()
  target_include_directories(srt-sink PRIVATE "${SRT_INCLUDE_DIR}")
  target_link_libraries(srt-sink PRIVATE "${SRT_LIBRARY}")
endif()

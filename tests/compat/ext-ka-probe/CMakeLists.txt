# ext-ka-probe — SRTLA extended-keepalive conformance probe.
#
# A standalone wire-protocol client (no libsrt, no srtla internal headers); it
# only needs a C++17 toolchain. Built solely under BUILD_COMPAT_TESTS.

add_executable(ext-ka-probe main.cpp)
target_compile_features(ext-ka-probe PRIVATE cxx_std_17)
target_compile_options(ext-ka-probe PRIVATE -Wall -Wextra)

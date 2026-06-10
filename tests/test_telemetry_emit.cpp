/*
    srtla - SRT transport proxy with link aggregation
    Copyright (C) 2026 CeraLive

    Tests for src/sender_telemetry.h — the pure sender telemetry serializer and
    atomic stats-file publish (Option A of ADR-001).

    What is pinned here:

      * Schema correctness — build_telemetry_json() reproduces the ADR canonical
        example byte-for-byte (golden fixtures tests/golden/telemetry_*.json):
        every field present, correctly typed, and the *mandated* bitrate
        unit conversion (wire bytes/s -> JSON bitrate_bps bits/s, x8) applied.

      * Empty state — zero active links serialize to "connections": [] with a
        fresh timestamp, "running but idle" distinct from "absent".

      * Cadence / update propagation — a publish appears, a later publish
        atomically replaces it in place, and no .tmp sibling is left behind.

      * Atomicity — a reader in a tight 1000-iteration loop against a
        continuously-rewriting writer never observes a torn/partial document.
        This is the property that justifies choosing the rename(2) transport.
*/

#include <gtest/gtest.h>

#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include <unistd.h>

#include "sender_telemetry.h"

#ifndef TELEMETRY_GOLDEN_DIR
#define TELEMETRY_GOLDEN_DIR "."
#endif

namespace {

using srtla::sender::build_telemetry_json;
using srtla::sender::remove_telemetry_file;
using srtla::sender::TelemetrySnapshot;
using srtla::sender::write_telemetry_atomic;

std::string read_file(const std::string &path) {
  std::ifstream f(path, std::ios::binary);
  if (!f.is_open()) {
    return std::string();
  }
  std::stringstream ss;
  ss << f.rdbuf();
  return ss.str();
}

std::string make_temp_path() {
  char tmpl[] = "/tmp/srtla_telemetry_test_XXXXXX";
  int fd = mkstemp(tmpl);
  if (fd >= 0) {
    close(fd);
  }
  return std::string(tmpl);
}

// Minimal, dependency-free structural validator: confirms a fully-formed JSON
// *object*. Enough to detect a truncated/torn write — a partial document would
// fail the brace/bracket balance or the first/last-char check. (We deliberately
// avoid pulling in a JSON parser: "no new dependencies", ADR-001.)
bool is_complete_json_object(const std::string &s) {
  size_t start = s.find_first_not_of(" \t\r\n");
  size_t end = s.find_last_not_of(" \t\r\n");
  if (start == std::string::npos || end == std::string::npos) {
    return false;
  }
  if (s[start] != '{' || s[end] != '}') {
    return false;
  }

  int depth = 0;
  bool in_str = false;
  bool esc = false;
  for (size_t i = start; i <= end; ++i) {
    char ch = s[i];
    if (in_str) {
      if (esc) {
        esc = false;
      } else if (ch == '\\') {
        esc = true;
      } else if (ch == '"') {
        in_str = false;
      }
      continue;
    }
    if (ch == '"') {
      in_str = true;
    } else if (ch == '{' || ch == '[') {
      depth++;
    } else if (ch == '}' || ch == ']') {
      if (--depth < 0) {
        return false;
      }
    }
  }
  return depth == 0 && !in_str;
}

// --- Schema correctness (golden-file) --------------------------------------

TEST(TelemetrySchema, FullSnapshotMatchesGolden) {
  std::string golden = read_file(TELEMETRY_GOLDEN_DIR "/telemetry_full.json");
  ASSERT_FALSE(golden.empty()) << "golden fixture telemetry_full.json not found";

  // Inputs chosen so the x8 bitrate conversion lands on the ADR example:
  //   312500 B/s -> 2500000 bps, 150000 B/s -> 1200000 bps.
  std::vector<TelemetrySnapshot> conns = {
      TelemetrySnapshot{0, 42, 3, 85, 8192, 100, 312500},
      TelemetrySnapshot{1, 73, 11, 55, 4096, 240, 150000},
  };

  EXPECT_EQ(build_telemetry_json(1749556546000ULL, conns), golden);
}

TEST(TelemetrySchema, BitrateConvertedBytesToBits) {
  std::vector<TelemetrySnapshot> conns = {
      TelemetrySnapshot{0, 0, 0, 100, 0, 0, 312500},
  };
  std::string j = build_telemetry_json(0, conns);
  EXPECT_NE(j.find("\"bitrate_bps\": 2500000"), std::string::npos)
      << "bitrate must be published in bits/s (bytes/s x 8)";
  EXPECT_EQ(j.find("312500"), std::string::npos)
      << "raw bytes/s must never leak into the JSON";
}

// --- Empty state ------------------------------------------------------------

TEST(TelemetrySchema, EmptyConnectionsMatchesGolden) {
  std::string golden = read_file(TELEMETRY_GOLDEN_DIR "/telemetry_empty.json");
  ASSERT_FALSE(golden.empty()) << "golden fixture telemetry_empty.json not found";

  std::string j = build_telemetry_json(1749556546000ULL, {});
  EXPECT_EQ(j, golden);
  EXPECT_NE(j.find("\"connections\": []"), std::string::npos);
  EXPECT_TRUE(is_complete_json_object(j));
}

// --- Cadence / update propagation ------------------------------------------

TEST(TelemetryWrite, AtomicWriteAppearsAndUpdatesInPlace) {
  std::string path = make_temp_path();
  remove_telemetry_file(path); // start with no live file

  ASSERT_TRUE(write_telemetry_atomic(path, build_telemetry_json(111, {})));
  std::string c1 = read_file(path);
  EXPECT_TRUE(is_complete_json_object(c1));
  EXPECT_NE(c1.find("\"last_updated_ms\": 111"), std::string::npos);

  ASSERT_TRUE(write_telemetry_atomic(path, build_telemetry_json(222, {})));
  std::string c2 = read_file(path);
  EXPECT_NE(c2.find("\"last_updated_ms\": 222"), std::string::npos);
  EXPECT_EQ(c2.find("\"last_updated_ms\": 111"), std::string::npos)
      << "a publish must replace the previous snapshot, not append";

  // A successful publish leaves no temp sibling behind.
  EXPECT_TRUE(read_file(path + ".tmp").empty());

  remove_telemetry_file(path);
}

TEST(TelemetryWrite, RemoveDeletesLiveAndTempFiles) {
  std::string path = make_temp_path();
  ASSERT_TRUE(write_telemetry_atomic(path, build_telemetry_json(1, {})));
  EXPECT_FALSE(read_file(path).empty());

  remove_telemetry_file(path);
  EXPECT_TRUE(read_file(path).empty()) << "live file must be gone after remove";
  EXPECT_TRUE(read_file(path + ".tmp").empty());
}

// --- Atomicity --------------------------------------------------------------

TEST(TelemetryAtomicity, ConcurrentReaderNeverSeesTornWrite) {
  std::string path = make_temp_path();
  // Seed one complete snapshot so the reader always finds a live file.
  ASSERT_TRUE(write_telemetry_atomic(path, build_telemetry_json(1, {})));

  std::atomic<bool> stop{false};
  std::atomic<uint64_t> writes{0};

  // Alternating small/large snapshots maximize the byte-length delta between
  // successive writes, so any non-atomic publish would be caught as an
  // unbalanced document by is_complete_json_object().
  std::vector<TelemetrySnapshot> small = {
      TelemetrySnapshot{0, 1, 1, 100, 10, 1, 1000},
  };
  std::vector<TelemetrySnapshot> big;
  for (uint32_t i = 0; i < 64; ++i) {
    big.push_back(TelemetrySnapshot{i, i, i, 100, static_cast<int32_t>(i) * 100,
                                    static_cast<int32_t>(i), i * 1000});
  }

  std::thread writer([&] {
    uint64_t t = 2;
    while (!stop.load(std::memory_order_relaxed)) {
      const std::vector<TelemetrySnapshot> &v = (t & 1ULL) ? small : big;
      write_telemetry_atomic(path, build_telemetry_json(t, v));
      writes.fetch_add(1, std::memory_order_relaxed);
      ++t;
    }
  });

  int parse_errors = 0;
  for (int i = 0; i < 1000; ++i) {
    std::string content = read_file(path);
    if (!is_complete_json_object(content)) {
      ++parse_errors;
    }
  }

  stop.store(true, std::memory_order_relaxed);
  writer.join();
  remove_telemetry_file(path);

  EXPECT_EQ(parse_errors, 0)
      << "reader observed a torn/partial JSON document across 1000 reads";
  EXPECT_GT(writes.load(), 0u) << "writer never ran";
}

} // namespace

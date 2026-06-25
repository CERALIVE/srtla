// ts_continuity_test.cpp — hermetic unit test for the MPEG-TS continuity
// tracker that backs srt-sink's ts_packets / ts_sync_errors / ts_cc_errors
// metrics. No libsrt, no network, no ffmpeg: it synthesises transport-stream
// bytes in memory, feeds them to tscont::Tracker, and asserts the metric is
// falsifiable — a clean stream yields cc_errors==0 while a stream with a
// dropped packet yields cc_errors>0. Built under BUILD_COMPAT_TESTS and wired
// into ctest so the guarantee is checked on every compat-enabled build.

#include "ts_continuity.h"

#include <cstdint>
#include <cstdio>
#include <vector>

namespace {

int g_failures = 0;

#define CHECK(cond, msg)                                                        \
  do {                                                                          \
    if (!(cond)) {                                                              \
      std::fprintf(stderr, "FAIL: %s (%s:%d)\n", (msg), __FILE__, __LINE__);    \
      ++g_failures;                                                             \
    }                                                                           \
  } while (0)

// Build one 188-byte TS packet.
//   pid           13-bit packet identifier
//   cc            4-bit continuity counter
//   payload       true  -> adaptation_field_control "01" (payload only)
//                 false -> "10" (adaptation only; CC must NOT increment)
//   discontinuity true  -> set the adaptation-field discontinuity_indicator
//                          (forces an adaptation field to be present)
std::vector<uint8_t> make_packet(uint16_t pid, uint8_t cc, bool payload = true,
                                 bool discontinuity = false) {
  std::vector<uint8_t> p(tscont::TS_PACKET_SIZE, 0xFF);
  p[0] = tscont::TS_SYNC_BYTE;
  p[1] = static_cast<uint8_t>((pid >> 8) & 0x1F);
  p[2] = static_cast<uint8_t>(pid & 0xFF);

  uint8_t afc;
  if (discontinuity) {
    afc = payload ? 0x3 : 0x2; // adaptation field required to carry the flag
  } else {
    afc = payload ? 0x1 : 0x2;
  }
  p[3] = static_cast<uint8_t>((afc << 4) | (cc & 0x0F));
  if (afc == 0x2 || afc == 0x3) {
    p[4] = (afc == 0x2) ? 183 : 1;            // adaptation_field_length
    p[5] = discontinuity ? 0x80 : 0x00;       // discontinuity_indicator (bit 7)
  }
  return p;
}

void append(std::vector<uint8_t> &s, const std::vector<uint8_t> &p) {
  s.insert(s.end(), p.begin(), p.end());
}

} // namespace

int main() {
  using tscont::Tracker;

  // 1) Clean stream: one PID, CC 0..15 wrapping over 64 packets -> no errors.
  {
    std::vector<uint8_t> s;
    const int N = 64;
    for (int i = 0; i < N; ++i) append(s, make_packet(0x100, static_cast<uint8_t>(i & 0x0F)));
    Tracker t;
    t.feed(s.data(), s.size());
    CHECK(t.packets() == static_cast<uint64_t>(N), "clean: packet count");
    CHECK(t.sync_errors() == 0, "clean: no sync errors");
    CHECK(t.cc_errors() == 0, "clean: no cc errors");
  }

  // 2) Dropped packet: omit the packet whose CC would be 5 -> >=1 cc error.
  //    This is the falsifiability proof: a real drop must move the metric.
  {
    std::vector<uint8_t> s;
    for (int i = 0; i < 10; ++i) {
      if (i == 5) continue; // physically drop one packet, preserving alignment
      append(s, make_packet(0x100, static_cast<uint8_t>(i & 0x0F)));
    }
    Tracker t;
    t.feed(s.data(), s.size());
    CHECK(t.packets() == 9, "drop: packet count");
    CHECK(t.sync_errors() == 0, "drop: no sync errors");
    CHECK(t.cc_errors() >= 1, "drop: cc error detected");
  }

  // 3) Sync error: clobber a sync byte in place (alignment preserved).
  {
    std::vector<uint8_t> s;
    for (int i = 0; i < 4; ++i) append(s, make_packet(0x100, static_cast<uint8_t>(i & 0x0F)));
    s[2 * tscont::TS_PACKET_SIZE] = 0x00; // 3rd packet's sync byte
    Tracker t;
    t.feed(s.data(), s.size());
    CHECK(t.sync_errors() >= 1, "sync: bad sync byte detected");
  }

  // 4) Null PID (0x1FFF) carries no continuity: an arbitrary CC jump is benign.
  {
    std::vector<uint8_t> s;
    append(s, make_packet(0x1FFF, 3));
    append(s, make_packet(0x1FFF, 9));
    Tracker t;
    t.feed(s.data(), s.size());
    CHECK(t.cc_errors() == 0, "null-pid: no cc error");
  }

  // 5) discontinuity_indicator suppresses the CC-jump error.
  {
    std::vector<uint8_t> s;
    append(s, make_packet(0x100, 4));
    append(s, make_packet(0x100, 9, /*payload=*/true, /*discontinuity=*/true));
    Tracker t;
    t.feed(s.data(), s.size());
    CHECK(t.cc_errors() == 0, "discontinuity-indicator: suppresses error");
  }

  // 6) Adaptation-only packet (no payload) must not increment CC: a repeated CC
  //    across a "10" packet is correct, not an error.
  {
    std::vector<uint8_t> s;
    append(s, make_packet(0x100, 4));                       // payload, cc=4
    append(s, make_packet(0x100, 4, /*payload=*/false));    // adaptation only, cc stays 4
    append(s, make_packet(0x100, 5));                       // payload, cc=5
    Tracker t;
    t.feed(s.data(), s.size());
    CHECK(t.cc_errors() == 0, "adaptation-only: cc hold is not an error");
  }

  // 7) Carry buffer: feeding the SAME clean stream in ragged sub-188 chunks
  //    (TS packets straddle srt_recv boundaries) yields identical counts.
  {
    std::vector<uint8_t> s;
    const int N = 40;
    for (int i = 0; i < N; ++i) append(s, make_packet(0x021, static_cast<uint8_t>(i & 0x0F)));
    Tracker t;
    size_t off = 0;
    const size_t chunk = 100; // deliberately not a multiple of 188
    while (off < s.size()) {
      const size_t n = (off + chunk <= s.size()) ? chunk : (s.size() - off);
      t.feed(s.data() + off, n);
      off += n;
    }
    CHECK(t.packets() == static_cast<uint64_t>(N), "carry: packet count");
    CHECK(t.sync_errors() == 0, "carry: no sync errors");
    CHECK(t.cc_errors() == 0, "carry: no cc errors");
  }

  if (g_failures == 0) {
    std::printf("ts-continuity-test: all checks passed\n");
    return 0;
  }
  std::fprintf(stderr, "ts-continuity-test: %d check(s) failed\n", g_failures);
  return 1;
}

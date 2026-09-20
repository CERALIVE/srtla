// ts_continuity.h — MPEG-TS continuity / sync tracking for the srt-sink helper.
//
// An SRT *live* payload carries one or more contiguous 188-byte MPEG-TS
// packets. This header reassembles the byte stream across srt_recv boundaries
// (a small carry buffer) and, per PID, tracks the 4-bit continuity counter so
// the sink can report objective transport-stream health alongside its byte
// counters:
//
//   packets       total 188-byte TS packets observed
//   sync_errors   packets whose sync byte != 0x47 (mis-alignment / corruption)
//   cc_errors     continuity-counter discontinuities — a per-PID CC step other
//                 than +1 mod 16 on a payload-bearing packet — EXCLUDING the
//                 null PID (0x1FFF) and packets carrying the adaptation-field
//                 discontinuity_indicator (an intentional, signalled break).
//
// CC semantics (ISO/IEC 13818-1 §2.4.3.3): the continuity_counter only
// increments on packets that carry a payload (adaptation_field_control 01/11);
// adaptation-only packets (10) and the reserved value (00) leave it unchanged.
// We model that so a clean stream with PCR-only stuffing never false-positives.
//
// Header-only and dependency-free (no libsrt, no srtla internals) so the parser
// is unit-testable in isolation; srt-sink simply feeds it the bytes srt_recv
// delivers. A duplicate packet (same CC, payload present) is counted as a
// discontinuity here — the spec permits a single duplicate, but a measurement
// sink errs toward visibility and real encoder output does not duplicate.

#ifndef SRTLA_COMPAT_TS_CONTINUITY_H
#define SRTLA_COMPAT_TS_CONTINUITY_H

#include <cstddef>
#include <cstdint>

namespace tscont {

inline constexpr size_t TS_PACKET_SIZE = 188;
inline constexpr uint8_t TS_SYNC_BYTE = 0x47;
inline constexpr uint16_t TS_NULL_PID = 0x1FFF; // 13-bit null-packet PID
inline constexpr int TS_PID_COUNT = 8192;        // 2^13 possible PIDs

class Tracker {
public:
  Tracker() {
    for (int i = 0; i < TS_PID_COUNT; ++i) last_cc_[i] = -1; // -1 = unseen
  }

  uint64_t packets() const { return packets_; }
  uint64_t sync_errors() const { return sync_errors_; }
  uint64_t cc_errors() const { return cc_errors_; }

  // Feed the raw bytes delivered by one srt_recv. Packets straddling the
  // previous call are completed first via the carry buffer, so chunking is
  // irrelevant to the counts.
  void feed(const uint8_t *data, size_t len) {
    if (data == nullptr || len == 0) return;
    size_t off = 0;

    // Complete a packet left half-read at the end of the previous feed().
    if (carry_len_ > 0) {
      const size_t need = TS_PACKET_SIZE - carry_len_;
      const size_t take = need < len ? need : len;
      for (size_t i = 0; i < take; ++i) carry_[carry_len_ + i] = data[i];
      carry_len_ += take;
      off += take;
      if (carry_len_ < TS_PACKET_SIZE) return; // still incomplete
      parse_packet(carry_);
      carry_len_ = 0;
    }

    while (off + TS_PACKET_SIZE <= len) {
      parse_packet(data + off);
      off += TS_PACKET_SIZE;
    }

    // Stash the sub-packet remainder for the next feed().
    const size_t rem = len - off;
    for (size_t i = 0; i < rem; ++i) carry_[i] = data[off + i];
    carry_len_ = rem;
  }

private:
  void parse_packet(const uint8_t *p) {
    ++packets_;
    if (p[0] != TS_SYNC_BYTE) {
      ++sync_errors_;
      return; // un-aligned/corrupt: PID and CC fields are untrustworthy
    }

    const uint16_t pid =
        static_cast<uint16_t>((static_cast<uint16_t>(p[1] & 0x1F) << 8) | p[2]);
    if (pid == TS_NULL_PID) return; // null packets carry no continuity

    const uint8_t afc = static_cast<uint8_t>((p[3] >> 4) & 0x03);
    const bool has_payload = (afc == 0x01 || afc == 0x03);
    const bool has_adaptation = (afc == 0x02 || afc == 0x03);
    const uint8_t cc = static_cast<uint8_t>(p[3] & 0x0F);

    bool discontinuity = false;
    if (has_adaptation) {
      const uint8_t af_len = p[4];           // adaptation_field_length
      if (af_len > 0) {
        discontinuity = (p[5] & 0x80) != 0;  // discontinuity_indicator (bit 7)
      }
    }

    const int prev = last_cc_[pid];
    if (prev >= 0 && !discontinuity) {
      const uint8_t expected =
          has_payload ? static_cast<uint8_t>((prev + 1) & 0x0F)
                      : static_cast<uint8_t>(prev);
      if (cc != expected) ++cc_errors_;
    }
    last_cc_[pid] = static_cast<int>(cc);
  }

  uint64_t packets_ = 0;
  uint64_t sync_errors_ = 0;
  uint64_t cc_errors_ = 0;
  int last_cc_[TS_PID_COUNT];
  uint8_t carry_[TS_PACKET_SIZE];
  size_t carry_len_ = 0;
};

} // namespace tscont

#endif // SRTLA_COMPAT_TS_CONTINUITY_H

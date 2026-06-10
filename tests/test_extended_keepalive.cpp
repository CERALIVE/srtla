/*
    srtla - SRT transport proxy with link aggregation
    Copyright (C) 2025 CeraLive

    Tests for the extended-keepalive wire format and the sender-telemetry
    activation / fallback semantics it drives.

    Two layers are pinned here:
      1. parse_keepalive_conn_info() (src/common.c) — the byte-level parser
         that decides whether a 0x9000 packet carries a 0xC01F/0x0001 extended
         payload, and extracts connection_info_t when it does.
      2. ConnectionStats (src/receiver_config.h) — the persistent
         "supports_extended_keepalives" capability flag vs. the transient
         "has_valid_sender_telemetry()" staleness/meaningfulness check, which
         together select the telemetry quality path or the legacy fallback.
*/

#include <gtest/gtest.h>

#include <cstdint>
#include <cstring>

extern "C" {
#include "common.h"
}

#include "receiver_config.h"

namespace {

// Builds a wire-format SRTLA keepalive with the given header/telemetry fields,
// laid out big-endian exactly as parse_keepalive_conn_info() reads it. The
// caller controls type/magic/version so negative cases can corrupt one field.
void put_be16(uint8_t *p, uint16_t v) {
  p[0] = static_cast<uint8_t>((v >> 8) & 0xFF);
  p[1] = static_cast<uint8_t>(v & 0xFF);
}
void put_be32(uint8_t *p, uint32_t v) {
  p[0] = static_cast<uint8_t>((v >> 24) & 0xFF);
  p[1] = static_cast<uint8_t>((v >> 16) & 0xFF);
  p[2] = static_cast<uint8_t>((v >> 8) & 0xFF);
  p[3] = static_cast<uint8_t>(v & 0xFF);
}

struct ExtKaFields {
  uint16_t type = SRTLA_TYPE_KEEPALIVE;
  uint16_t magic = SRTLA_KEEPALIVE_MAGIC;
  uint16_t version = SRTLA_KEEPALIVE_EXT_VERSION;
  uint32_t conn_id = 0;
  int32_t window = 8192;
  int32_t in_flight = 100;
  uint32_t rtt_ms = 30;
  uint32_t nak_count = 2;
  uint32_t bitrate = 250000;
};

void build_ext_ka(uint8_t out[SRTLA_KEEPALIVE_EXT_LEN], const ExtKaFields &f) {
  std::memset(out, 0, SRTLA_KEEPALIVE_EXT_LEN);
  put_be16(out + 0, f.type);
  put_be16(out + 10, f.magic);
  put_be16(out + 12, f.version);
  put_be32(out + 14, f.conn_id);
  put_be32(out + 18, static_cast<uint32_t>(f.window));
  put_be32(out + 22, static_cast<uint32_t>(f.in_flight));
  put_be32(out + 26, f.rtt_ms);
  put_be32(out + 30, f.nak_count);
  put_be32(out + 34, f.bitrate);
}

// Mirrors SRTLAHandler::update_connection_telemetry: on a successful parse the
// receiver marks the capability flag and copies telemetry into the stats. Tests
// use this to assert the activation/fallback semantics without a live handler.
void apply_telemetry(srtla::ConnectionStats &stats, const connection_info_t &info,
                     time_t when) {
  stats.sender_supports_extended_keepalives = true;
  stats.rtt_ms = info.rtt_ms;
  stats.window = info.window;
  stats.in_flight = info.in_flight;
  stats.sender_nak_count = info.nak_count;
  stats.sender_bitrate_bps = info.bitrate_bytes_per_sec;
  stats.last_keepalive = when;
}

} // namespace

// ============================================================================
// parse_keepalive_conn_info — activation
// ============================================================================

TEST(ExtKeepaliveParse, ValidPacketParsesAllFields) {
  ExtKaFields f;
  f.conn_id = 0xDEADBEEF;
  f.window = 16384;
  f.in_flight = 321;
  f.rtt_ms = 42;
  f.nak_count = 7;
  f.bitrate = 250000;

  uint8_t pkt[SRTLA_KEEPALIVE_EXT_LEN];
  build_ext_ka(pkt, f);

  connection_info_t info;
  std::memset(&info, 0, sizeof(info));
  ASSERT_EQ(parse_keepalive_conn_info(pkt, SRTLA_KEEPALIVE_EXT_LEN, &info), 1);

  EXPECT_EQ(info.conn_id, 0xDEADBEEFu);
  EXPECT_EQ(info.window, 16384);
  EXPECT_EQ(info.in_flight, 321);
  EXPECT_EQ(info.rtt_ms, 42u);
  EXPECT_EQ(info.nak_count, 7u);
  EXPECT_EQ(info.bitrate_bytes_per_sec, 250000u);
}

TEST(ExtKeepaliveParse, WrongMagicLeavesCapabilityUnset) {
  ExtKaFields f;
  f.magic = 0x1234;  // not SRTLA_KEEPALIVE_MAGIC
  uint8_t pkt[SRTLA_KEEPALIVE_EXT_LEN];
  build_ext_ka(pkt, f);

  connection_info_t info;
  EXPECT_EQ(parse_keepalive_conn_info(pkt, SRTLA_KEEPALIVE_EXT_LEN, &info), 0);

  // The handler only flips the flag when the parser returns 1, so a wrong-magic
  // packet must leave the connection looking like a legacy sender.
  srtla::ConnectionStats stats;
  EXPECT_FALSE(stats.supports_extended_keepalives());
}

TEST(ExtKeepaliveParse, WrongVersionTreatedAsLegacy) {
  ExtKaFields f;
  f.version = 0x0002;  // not SRTLA_KEEPALIVE_EXT_VERSION
  uint8_t pkt[SRTLA_KEEPALIVE_EXT_LEN];
  build_ext_ka(pkt, f);

  connection_info_t info;
  EXPECT_EQ(parse_keepalive_conn_info(pkt, SRTLA_KEEPALIVE_EXT_LEN, &info), 0);

  srtla::ConnectionStats stats;
  EXPECT_FALSE(stats.supports_extended_keepalives());
}

TEST(ExtKeepaliveParse, WrongPacketTypeRejected) {
  ExtKaFields f;
  f.type = SRTLA_TYPE_ACK;  // valid magic/version but not a keepalive
  uint8_t pkt[SRTLA_KEEPALIVE_EXT_LEN];
  build_ext_ka(pkt, f);

  connection_info_t info;
  EXPECT_EQ(parse_keepalive_conn_info(pkt, SRTLA_KEEPALIVE_EXT_LEN, &info), 0);
}

TEST(ExtKeepaliveParse, TruncatedPacketSafeFallback) {
  ExtKaFields f;
  uint8_t pkt[SRTLA_KEEPALIVE_EXT_LEN];
  build_ext_ka(pkt, f);

  connection_info_t info;
  // One byte short of the extended length must reject without reading past the
  // buffer; the bare 2-byte keepalive is the smallest legacy form.
  EXPECT_EQ(parse_keepalive_conn_info(pkt, SRTLA_KEEPALIVE_EXT_LEN - 1, &info), 0);
  EXPECT_EQ(parse_keepalive_conn_info(pkt, 2, &info), 0);
  EXPECT_EQ(parse_keepalive_conn_info(pkt, 0, &info), 0);
}

TEST(ExtKeepaliveParse, BareLegacyKeepaliveSetsNoFlag) {
  uint8_t pkt[2];
  put_be16(pkt, SRTLA_TYPE_KEEPALIVE);

  connection_info_t info;
  EXPECT_EQ(parse_keepalive_conn_info(pkt, 2, &info), 0);

  srtla::ConnectionStats stats;
  EXPECT_FALSE(stats.supports_extended_keepalives());
}

// ============================================================================
// ConnectionStats — telemetry validity, staleness, and the zero-value edge
// ============================================================================

TEST(ExtKeepaliveTelemetry, FreshValidTelemetryIsUsable) {
  ExtKaFields f;
  f.rtt_ms = 30;
  f.window = 8192;
  uint8_t pkt[SRTLA_KEEPALIVE_EXT_LEN];
  build_ext_ka(pkt, f);

  connection_info_t info;
  ASSERT_EQ(parse_keepalive_conn_info(pkt, SRTLA_KEEPALIVE_EXT_LEN, &info), 1);

  const time_t now = 1000;
  srtla::ConnectionStats stats;
  apply_telemetry(stats, info, now);

  EXPECT_TRUE(stats.supports_extended_keepalives());
  EXPECT_TRUE(stats.has_valid_sender_telemetry(now));
}

TEST(ExtKeepaliveTelemetry, ZeroValuePayloadActivatesButHasNoValidTelemetry) {
  // EC5: a sender that supports extended keepalives but reports rtt=0 AND
  // window=0. The capability flag is set (the packet IS a valid extended KA),
  // yet has_valid_sender_telemetry() returns false because neither RTT nor
  // window carries usable signal. This confusing-but-current split is the
  // contract the quality evaluator relies on, so pin both halves explicitly.
  ExtKaFields f;
  f.rtt_ms = 0;
  f.window = 0;
  f.in_flight = 0;
  f.nak_count = 0;
  f.bitrate = 0;
  uint8_t pkt[SRTLA_KEEPALIVE_EXT_LEN];
  build_ext_ka(pkt, f);

  connection_info_t info;
  ASSERT_EQ(parse_keepalive_conn_info(pkt, SRTLA_KEEPALIVE_EXT_LEN, &info), 1);
  EXPECT_EQ(info.rtt_ms, 0u);
  EXPECT_EQ(info.window, 0);

  const time_t now = 1000;
  srtla::ConnectionStats stats;
  apply_telemetry(stats, info, now);

  EXPECT_TRUE(stats.supports_extended_keepalives());
  EXPECT_FALSE(stats.has_valid_sender_telemetry(now));
}

TEST(ExtKeepaliveTelemetry, StaleTelemetryExpiresPastThreshold) {
  ExtKaFields f;
  f.rtt_ms = 30;
  f.window = 8192;
  uint8_t pkt[SRTLA_KEEPALIVE_EXT_LEN];
  build_ext_ka(pkt, f);

  connection_info_t info;
  ASSERT_EQ(parse_keepalive_conn_info(pkt, SRTLA_KEEPALIVE_EXT_LEN, &info), 1);

  const time_t recv_at = 1000;
  srtla::ConnectionStats stats;
  apply_telemetry(stats, info, recv_at);

  // 3s elapsed > KEEPALIVE_STALENESS_THRESHOLD (2s) => telemetry no longer
  // usable, while the capability flag still persists for the connection.
  const time_t now = recv_at + 3;
  EXPECT_GT(now - recv_at, srtla::KEEPALIVE_STALENESS_THRESHOLD);
  EXPECT_FALSE(stats.has_valid_sender_telemetry(now));
  EXPECT_TRUE(stats.supports_extended_keepalives());

  // At exactly the threshold the telemetry is still considered fresh.
  EXPECT_TRUE(stats.has_valid_sender_telemetry(
      recv_at + srtla::KEEPALIVE_STALENESS_THRESHOLD));
}

TEST(ExtKeepaliveTelemetry, NoKeepaliveYetIsNotValid) {
  srtla::ConnectionStats stats;
  EXPECT_EQ(stats.last_keepalive, 0);
  EXPECT_FALSE(stats.has_valid_sender_telemetry(1000));
  EXPECT_FALSE(stats.supports_extended_keepalives());
}

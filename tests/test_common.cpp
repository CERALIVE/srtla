/*
    srtla - SRT transport proxy with link aggregation
    Copyright (C) 2025 IRLServer.com

    Tests for common.c utility functions
*/

#include <gtest/gtest.h>
#include <cstring>
#include <arpa/inet.h>
#include <endian.h>

extern "C" {
#include "common.h"
}

// ============================================================================
// parse_ip tests
// ============================================================================

TEST(ParseIp, ValidIPv4Address) {
    struct sockaddr_in addr;
    int result = parse_ip(&addr, const_cast<char*>("192.168.1.1"));
    
    EXPECT_EQ(result, 0);
    EXPECT_EQ(addr.sin_family, AF_INET);
    EXPECT_EQ(addr.sin_addr.s_addr, inet_addr("192.168.1.1"));
}

TEST(ParseIp, ValidLocalhostAddress) {
    struct sockaddr_in addr;
    int result = parse_ip(&addr, const_cast<char*>("127.0.0.1"));
    
    EXPECT_EQ(result, 0);
    EXPECT_EQ(addr.sin_family, AF_INET);
    EXPECT_EQ(addr.sin_addr.s_addr, inet_addr("127.0.0.1"));
}

TEST(ParseIp, InvalidIPAddress) {
    struct sockaddr_in addr;
    int result = parse_ip(&addr, const_cast<char*>("not.an.ip.address"));
    
    EXPECT_EQ(result, -1);
}

TEST(ParseIp, EmptyString) {
    struct sockaddr_in addr;
    int result = parse_ip(&addr, const_cast<char*>(""));
    
    EXPECT_EQ(result, -1);
}

// ============================================================================
// parse_port tests
// ============================================================================

TEST(ParsePort, ValidPort) {
    EXPECT_EQ(parse_port(const_cast<char*>("5000")), 5000);
    EXPECT_EQ(parse_port(const_cast<char*>("1")), 1);
    EXPECT_EQ(parse_port(const_cast<char*>("65535")), 65535);
    EXPECT_EQ(parse_port(const_cast<char*>("8080")), 8080);
}

TEST(ParsePort, InvalidPortZero) {
    EXPECT_EQ(parse_port(const_cast<char*>("0")), -2);
}

TEST(ParsePort, InvalidPortNegative) {
    EXPECT_EQ(parse_port(const_cast<char*>("-1")), -2);
}

TEST(ParsePort, InvalidPortTooHigh) {
    EXPECT_EQ(parse_port(const_cast<char*>("65536")), -2);
    EXPECT_EQ(parse_port(const_cast<char*>("100000")), -2);
}

TEST(ParsePort, InvalidPortNonNumeric) {
    // strtol returns 0 for non-numeric, which triggers <= 0 check
    EXPECT_EQ(parse_port(const_cast<char*>("abc")), -2);
}

// ============================================================================
// get_srt_sn tests (sequence number extraction)
// ============================================================================

TEST(GetSrtSn, ValidSequenceNumber) {
    // SRT sequence number: first bit is 0 (data packet), rest is sequence number
    uint32_t pkt = htobe32(0x00001234);  // Sequence number 0x1234
    
    EXPECT_EQ(get_srt_sn(&pkt, sizeof(pkt)), 0x1234);
}

TEST(GetSrtSn, MaxSequenceNumber) {
    // Maximum valid sequence number (bit 31 = 0)
    uint32_t pkt = htobe32(0x7FFFFFFF);
    
    EXPECT_EQ(get_srt_sn(&pkt, sizeof(pkt)), 0x7FFFFFFF);
}

TEST(GetSrtSn, ControlPacket) {
    // Control packet has bit 31 set, should return -1
    uint32_t pkt = htobe32(0x80000000);
    
    EXPECT_EQ(get_srt_sn(&pkt, sizeof(pkt)), -1);
}

TEST(GetSrtSn, PacketTooSmall) {
    uint32_t pkt = 0;
    
    EXPECT_EQ(get_srt_sn(&pkt, 3), -1);  // Less than 4 bytes
    EXPECT_EQ(get_srt_sn(&pkt, 0), -1);
}

// ============================================================================
// get_srt_type tests
// ============================================================================

TEST(GetSrtType, HandshakeType) {
    uint16_t pkt = htobe16(SRT_TYPE_HANDSHAKE);
    
    EXPECT_EQ(get_srt_type(&pkt, sizeof(pkt)), SRT_TYPE_HANDSHAKE);
}

TEST(GetSrtType, AckType) {
    uint16_t pkt = htobe16(SRT_TYPE_ACK);
    
    EXPECT_EQ(get_srt_type(&pkt, sizeof(pkt)), SRT_TYPE_ACK);
}

TEST(GetSrtType, NakType) {
    uint16_t pkt = htobe16(SRT_TYPE_NAK);
    
    EXPECT_EQ(get_srt_type(&pkt, sizeof(pkt)), SRT_TYPE_NAK);
}

TEST(GetSrtType, ShutdownType) {
    uint16_t pkt = htobe16(SRT_TYPE_SHUTDOWN);
    
    EXPECT_EQ(get_srt_type(&pkt, sizeof(pkt)), SRT_TYPE_SHUTDOWN);
}

TEST(GetSrtType, SrtlaKeepalive) {
    uint16_t pkt = htobe16(SRTLA_TYPE_KEEPALIVE);
    
    EXPECT_EQ(get_srt_type(&pkt, sizeof(pkt)), SRTLA_TYPE_KEEPALIVE);
}

TEST(GetSrtType, PacketTooSmall) {
    uint16_t pkt = 0;
    
    EXPECT_EQ(get_srt_type(&pkt, 1), 0);
    EXPECT_EQ(get_srt_type(&pkt, 0), 0);
}

// ============================================================================
// is_srt_ack tests
// ============================================================================

TEST(IsSrtAck, ValidAck) {
    uint16_t pkt = htobe16(SRT_TYPE_ACK);
    
    EXPECT_TRUE(is_srt_ack(&pkt, sizeof(pkt)));
}

TEST(IsSrtAck, NotAck) {
    uint16_t pkt = htobe16(SRT_TYPE_NAK);
    
    EXPECT_FALSE(is_srt_ack(&pkt, sizeof(pkt)));
}

// ============================================================================
// is_srtla_keepalive tests
// ============================================================================

TEST(IsSrtlaKeepalive, ValidKeepalive) {
    uint16_t pkt = htobe16(SRTLA_TYPE_KEEPALIVE);
    
    EXPECT_TRUE(is_srtla_keepalive(&pkt, sizeof(pkt)));
}

TEST(IsSrtlaKeepalive, NotKeepalive) {
    uint16_t pkt = htobe16(SRT_TYPE_ACK);
    
    EXPECT_FALSE(is_srtla_keepalive(&pkt, sizeof(pkt)));
}

// ============================================================================
// is_srtla_reg1/reg2/reg3 tests
// ============================================================================

TEST(IsSrtlaReg1, ValidReg1) {
    // REG1 packet: 2 bytes type + 256 bytes ID = 258 bytes total
    uint8_t pkt[SRTLA_TYPE_REG1_LEN] = {0};
    uint16_t* type = reinterpret_cast<uint16_t*>(pkt);
    *type = htobe16(SRTLA_TYPE_REG1);
    
    EXPECT_TRUE(is_srtla_reg1(pkt, SRTLA_TYPE_REG1_LEN));
}

TEST(IsSrtlaReg1, WrongLength) {
    uint8_t pkt[SRTLA_TYPE_REG1_LEN] = {0};
    uint16_t* type = reinterpret_cast<uint16_t*>(pkt);
    *type = htobe16(SRTLA_TYPE_REG1);
    
    // Wrong length should return false
    EXPECT_FALSE(is_srtla_reg1(pkt, SRTLA_TYPE_REG1_LEN - 1));
    EXPECT_FALSE(is_srtla_reg1(pkt, SRTLA_TYPE_REG1_LEN + 1));
}

TEST(IsSrtlaReg2, ValidReg2) {
    uint8_t pkt[SRTLA_TYPE_REG2_LEN] = {0};
    uint16_t* type = reinterpret_cast<uint16_t*>(pkt);
    *type = htobe16(SRTLA_TYPE_REG2);
    
    EXPECT_TRUE(is_srtla_reg2(pkt, SRTLA_TYPE_REG2_LEN));
}

TEST(IsSrtlaReg3, ValidReg3) {
    uint8_t pkt[SRTLA_TYPE_REG3_LEN] = {0};
    uint16_t* type = reinterpret_cast<uint16_t*>(pkt);
    *type = htobe16(SRTLA_TYPE_REG3);
    
    EXPECT_TRUE(is_srtla_reg3(pkt, SRTLA_TYPE_REG3_LEN));
}

TEST(IsSrtlaReg3, WrongType) {
    uint8_t pkt[SRTLA_TYPE_REG3_LEN] = {0};
    uint16_t* type = reinterpret_cast<uint16_t*>(pkt);
    *type = htobe16(SRTLA_TYPE_REG1);  // Wrong type
    
    EXPECT_FALSE(is_srtla_reg3(pkt, SRTLA_TYPE_REG3_LEN));
}

// ============================================================================
// get_seconds and get_ms tests
// ============================================================================

TEST(GetSeconds, ReturnsValidTime) {
    time_t seconds;
    int result = get_seconds(&seconds);
    
    EXPECT_EQ(result, 0);
    EXPECT_GT(seconds, 0);  // Should be a positive timestamp
}

TEST(GetMs, ReturnsValidTime) {
    uint64_t ms;
    int result = get_ms(&ms);
    
    EXPECT_EQ(result, 0);
    EXPECT_GT(ms, 0ULL);  // Should be a positive timestamp
}

TEST(GetMs, MillisecondsIncreaseOverTime) {
    uint64_t ms1, ms2;
    
    get_ms(&ms1);
    // Small busy wait
    for (volatile int i = 0; i < 1000000; i++) {}
    get_ms(&ms2);
    
    EXPECT_GE(ms2, ms1);  // Time should not go backwards
}

/*
    srtla - SRT transport proxy with link aggregation
    Copyright (C) 2026 CeraLive

    Tests for src/protocol/pad_sendto.h.

    `pad_sendto` zero-pads UDP control packets to a 32-byte minimum
    so cellular/NAT path keepalive thresholds don't drop tiny SRTLA
    control frames (KEEPALIVE, REG_ERR, REG_NGP, REG3, SRTLA_ACK).
    For payloads >= 32 bytes it is a passthrough.

    Test strategy: bind a localhost UDP socket pair, call pad_sendto
    on the sender side, recvfrom on the receiver side, assert the
    on-wire byte count.
*/

#include <gtest/gtest.h>

#include <arpa/inet.h>
#include <cstring>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include "protocol/pad_sendto.h"

namespace {

// Bind a localhost UDP socket on an ephemeral port. Returns the fd
// and writes the bound port into *port.
int open_udp_socket(uint16_t *port) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        return -1;
    }
    struct sockaddr_in addr;
    std::memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (bind(fd, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    socklen_t len = sizeof(addr);
    if (getsockname(fd, reinterpret_cast<struct sockaddr *>(&addr), &len) < 0) {
        close(fd);
        return -1;
    }
    *port = ntohs(addr.sin_port);
    return fd;
}

struct sockaddr_in loopback_addr(uint16_t port) {
    struct sockaddr_in addr;
    std::memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(port);
    return addr;
}

} // namespace

TEST(PadSendto, PadsTwoByteKeepaliveTo32Bytes) {
    uint16_t recv_port = 0;
    int recv_fd = open_udp_socket(&recv_port);
    ASSERT_GE(recv_fd, 0) << "failed to bind recv socket";

    uint16_t send_port = 0;
    int send_fd = open_udp_socket(&send_port);
    ASSERT_GE(send_fd, 0) << "failed to bind send socket";

    auto dest = loopback_addr(recv_port);

    uint16_t keepalive = 0x9000; // SRTLA keepalive type byte pattern
    int rc = pad_sendto(send_fd, &keepalive, sizeof(keepalive), 0,
                        reinterpret_cast<const struct sockaddr *>(&dest),
                        sizeof(dest));
    EXPECT_EQ(rc, static_cast<int>(sizeof(keepalive)))
        << "pad_sendto must report the user-visible (unpadded) byte count";

    unsigned char buf[64];
    ssize_t n = recv(recv_fd, buf, sizeof(buf), 0);
    EXPECT_EQ(n, 32) << "wire packet must be padded to 32 bytes";
    EXPECT_EQ(std::memcmp(buf, &keepalive, sizeof(keepalive)), 0)
        << "leading bytes must match the original payload";
    for (int i = sizeof(keepalive); i < 32; ++i) {
        EXPECT_EQ(buf[i], 0) << "padding byte at offset " << i << " must be zero";
    }

    close(send_fd);
    close(recv_fd);
}

TEST(PadSendto, PassesThroughExactly32ByteFrame) {
    uint16_t recv_port = 0;
    int recv_fd = open_udp_socket(&recv_port);
    ASSERT_GE(recv_fd, 0);

    uint16_t send_port = 0;
    int send_fd = open_udp_socket(&send_port);
    ASSERT_GE(send_fd, 0);

    auto dest = loopback_addr(recv_port);

    unsigned char payload[32];
    for (int i = 0; i < 32; ++i) {
        payload[i] = static_cast<unsigned char>(i + 1);
    }

    int rc = pad_sendto(send_fd, payload, sizeof(payload), 0,
                        reinterpret_cast<const struct sockaddr *>(&dest),
                        sizeof(dest));
    EXPECT_EQ(rc, 32);

    unsigned char buf[64];
    ssize_t n = recv(recv_fd, buf, sizeof(buf), 0);
    EXPECT_EQ(n, 32);
    EXPECT_EQ(std::memcmp(buf, payload, 32), 0);

    close(send_fd);
    close(recv_fd);
}

TEST(PadSendto, PassesThroughLargerPayloadUnchanged) {
    uint16_t recv_port = 0;
    int recv_fd = open_udp_socket(&recv_port);
    ASSERT_GE(recv_fd, 0);

    uint16_t send_port = 0;
    int send_fd = open_udp_socket(&send_port);
    ASSERT_GE(send_fd, 0);

    auto dest = loopback_addr(recv_port);

    unsigned char payload[100];
    for (int i = 0; i < 100; ++i) {
        payload[i] = static_cast<unsigned char>(i ^ 0xAA);
    }

    int rc = pad_sendto(send_fd, payload, sizeof(payload), 0,
                        reinterpret_cast<const struct sockaddr *>(&dest),
                        sizeof(dest));
    EXPECT_EQ(rc, 100);

    unsigned char buf[200];
    ssize_t n = recv(recv_fd, buf, sizeof(buf), 0);
    EXPECT_EQ(n, 100);
    EXPECT_EQ(std::memcmp(buf, payload, 100), 0);

    close(send_fd);
    close(recv_fd);
}

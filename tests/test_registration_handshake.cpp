/*
    srtla - SRT transport proxy with link aggregation
    Copyright (C) 2026 CeraLive

    REG handshake state-machine characterization at the SRTLAHandler level.

    The two-phase SRTLA registration handshake lives in
    src/protocol/srtla_handler.cpp:

        REG1 (sender)  --> register_group()      --> REG2 (receiver)
        REG2 (sender)  --> register_connection() --> REG3 (receiver)

    register_group() / register_connection() are private, so these tests
    drive them through the only public entry point, process_packets(),
    which reads from the receiver's UDP socket via recvmmsg().

    Test seam (mirrors tests/test_pad_sendto.cpp):
      * srtla_socket_ is a REAL loopback UDP socket -- no mocking of the
        kernel, no network. pad_sendto() inside the handler writes straight
        back to whichever address recvmmsg() reported as the source.
      * each "sender" is a bound loopback UDP socket; it sends a REG frame
        to the receiver socket, the test calls process_packets(), then
        recvfrom()s the handler's reply off the same socket.
      * SO_RCVTIMEO bounds the negative ("no reply expected") assertions.

    Wire formats (src/common.h):
      * REG1 / REG2 : 2-byte big-endian type + SRTLA_ID_LEN(256)-byte id = 258 B
      * REG3        : 2-byte type, padded to 32 B on the wire by pad_sendto
      * REG_ERR/NGP : 2-byte type, padded to 32 B on the wire by pad_sendto

    A freshly created group's id() is the first 128 bytes of the sender's
    REG1 client_id followed by 128 receiver-generated random bytes
    (ConnectionGroup ctor). find_group_by_id() matches the full 256 bytes.

    Every test here asserts the CURRENT, shipped behavior (characterization).
    Behaviors that look surprising but are intentional/defensible are called
    out in comments; genuine defects would be tagged *_KNOWNBUG and logged in
    tests/KNOWN_BUGS.md (none found -- the file records that).
*/

#include <gtest/gtest.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <array>
#include <cstdint>
#include <cstring>
#include <memory>
#include <vector>

#include "connection/connection_registry.h"
#include "protocol/srt_handler.h"
#include "protocol/srtla_handler.h"
#include "quality/metrics_collector.h"

extern "C" {
#include "common.h"
}

using srtla::connection::ConnectionRegistry;
using srtla::protocol::SRTHandler;
using srtla::protocol::SRTLAHandler;
using srtla::quality::MetricsCollector;

namespace {

constexpr time_t kBaseTs = 100000;
constexpr int kRecvTimeoutMs = 300;

// Bind a localhost UDP socket on an ephemeral port with a bounded receive
// timeout (so negative assertions don't block forever). Writes the bound
// port into *port and returns the fd, or -1 on failure.
int open_udp_loopback(uint16_t *port) {
    int fd = ::socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) {
        return -1;
    }
    struct sockaddr_in addr;
    std::memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (::bind(fd, reinterpret_cast<struct sockaddr *>(&addr), sizeof(addr)) < 0) {
        ::close(fd);
        return -1;
    }
    socklen_t len = sizeof(addr);
    if (::getsockname(fd, reinterpret_cast<struct sockaddr *>(&addr), &len) < 0) {
        ::close(fd);
        return -1;
    }
    struct timeval tv;
    tv.tv_sec = 0;
    tv.tv_usec = kRecvTimeoutMs * 1000;
    ::setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
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

uint16_t wire_type(const uint8_t *buf, ssize_t n) {
    if (n < 2) {
        return 0;
    }
    return static_cast<uint16_t>((buf[0] << 8) | buf[1]);
}

// Build a 258-byte REG1/REG2 frame: big-endian type + 256-byte id payload.
std::vector<uint8_t> build_reg_frame(uint16_t type, const std::array<uint8_t, SRTLA_ID_LEN> &id) {
    std::vector<uint8_t> frame(SRTLA_TYPE_REG1_LEN, 0);
    frame[0] = static_cast<uint8_t>((type >> 8) & 0xff);
    frame[1] = static_cast<uint8_t>(type & 0xff);
    std::memcpy(frame.data() + 2, id.data(), SRTLA_ID_LEN);
    return frame;
}

// A recognizable, non-random client id so REG2 echo-back is checkable.
std::array<uint8_t, SRTLA_ID_LEN> make_client_id(uint8_t seed) {
    std::array<uint8_t, SRTLA_ID_LEN> id {};
    for (size_t i = 0; i < id.size(); ++i) {
        id[i] = static_cast<uint8_t>((i * 7 + seed) & 0xff);
    }
    return id;
}

} // namespace

class RegHandshakeTest : public ::testing::Test {
protected:
    void SetUp() override {
        srtla_fd_ = open_udp_loopback(&srtla_port_);
        ASSERT_GE(srtla_fd_, 0) << "failed to bind receiver socket";

        epoll_fd_ = ::epoll_create1(0);
        ASSERT_GE(epoll_fd_, 0) << "failed to create epoll fd";

        std::memset(&srt_addr_, 0, sizeof(srt_addr_));
        auto *in = reinterpret_cast<struct sockaddr_in *>(&srt_addr_);
        in->sin_family = AF_INET;
        in->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        in->sin_port = htons(9999);

        srt_handler_ = std::make_unique<SRTHandler>(srtla_fd_, srt_addr_, epoll_fd_, registry_);
        handler_ = std::make_unique<SRTLAHandler>(srtla_fd_, registry_, *srt_handler_, metrics_);
    }

    void TearDown() override {
        for (int fd : client_fds_) {
            if (fd >= 0) {
                ::close(fd);
            }
        }
        if (epoll_fd_ >= 0) {
            ::close(epoll_fd_);
        }
        if (srtla_fd_ >= 0) {
            ::close(srtla_fd_);
        }
    }

    // Create a bound loopback "sender" socket; tracked for teardown.
    int make_client() {
        uint16_t port = 0;
        int fd = open_udp_loopback(&port);
        EXPECT_GE(fd, 0) << "failed to bind client socket";
        if (fd >= 0) {
            client_fds_.push_back(fd);
        }
        return fd;
    }

    void send_frame(int client_fd, const std::vector<uint8_t> &frame) {
        auto dest = loopback_addr(srtla_port_);
        ssize_t sent = ::sendto(client_fd, frame.data(), frame.size(), 0,
                                reinterpret_cast<const struct sockaddr *>(&dest), sizeof(dest));
        ASSERT_EQ(sent, static_cast<ssize_t>(frame.size())) << "sendto to receiver failed";
    }

    int pump(time_t ts = kBaseTs) { return handler_->process_packets(ts); }

    // recvfrom the receiver's reply; returns byte count or -1 on timeout.
    ssize_t recv_reply(int client_fd, uint8_t *buf, size_t cap) {
        return ::recvfrom(client_fd, buf, cap, 0, nullptr, nullptr);
    }

    int srtla_fd_ = -1;
    int epoll_fd_ = -1;
    uint16_t srtla_port_ = 0;
    struct sockaddr_storage srt_addr_ {};
    ConnectionRegistry registry_;
    MetricsCollector metrics_;
    std::unique_ptr<SRTHandler> srt_handler_;
    std::unique_ptr<SRTLAHandler> handler_;
    std::vector<int> client_fds_;
};

// --- Transition 1: REG1 -> REG2 -------------------------------------------

TEST_F(RegHandshakeTest, Reg1CreatesGroupAndRepliesReg2) {
    int client = make_client();
    auto cid = make_client_id(0x11);
    send_frame(client, build_reg_frame(SRTLA_TYPE_REG1, cid));

    EXPECT_EQ(pump(), 1) << "receiver should read exactly one REG1";
    ASSERT_EQ(registry_.groups().size(), 1u) << "REG1 must create exactly one group";

    uint8_t reply[512];
    ssize_t n = recv_reply(client, reply, sizeof(reply));
    ASSERT_EQ(n, SRTLA_TYPE_REG2_LEN) << "REG2 reply must be the full 258-byte frame";
    EXPECT_EQ(wire_type(reply, n), SRTLA_TYPE_REG2);
}

TEST_F(RegHandshakeTest, Reg2ReplyEchoesClientIdInFullId) {
    int client = make_client();
    auto cid = make_client_id(0x22);
    send_frame(client, build_reg_frame(SRTLA_TYPE_REG1, cid));
    ASSERT_EQ(pump(), 1);

    uint8_t reply[512];
    ssize_t n = recv_reply(client, reply, sizeof(reply));
    ASSERT_EQ(n, SRTLA_TYPE_REG2_LEN);

    // The returned full_id keeps the sender's first half (128 bytes) and
    // appends 128 receiver-generated random bytes (ConnectionGroup ctor).
    const uint8_t *full_id = reply + 2;
    EXPECT_EQ(std::memcmp(full_id, cid.data(), SRTLA_ID_LEN / 2), 0)
        << "first 128 bytes of full_id must echo the REG1 client_id";

    // And that exact full_id resolves the just-created group.
    const auto &gid = registry_.groups()[0]->id();
    EXPECT_EQ(std::memcmp(full_id, gid.data(), SRTLA_ID_LEN), 0)
        << "full_id on the wire must equal the stored group id";
}

// --- Transition 2: REG2 -> REG3 (same sender completes the handshake) ------

TEST_F(RegHandshakeTest, Reg2AddsConnectionAndRepliesReg3) {
    int client = make_client();
    send_frame(client, build_reg_frame(SRTLA_TYPE_REG1, make_client_id(0x33)));
    ASSERT_EQ(pump(), 1);

    uint8_t reg2[512];
    ssize_t n2 = recv_reply(client, reg2, sizeof(reg2));
    ASSERT_EQ(n2, SRTLA_TYPE_REG2_LEN);

    // Reflect the full_id back as REG2.
    std::array<uint8_t, SRTLA_ID_LEN> full_id {};
    std::memcpy(full_id.data(), reg2 + 2, SRTLA_ID_LEN);
    send_frame(client, build_reg_frame(SRTLA_TYPE_REG2, full_id));
    ASSERT_EQ(pump(), 1);

    uint8_t reg3[64];
    ssize_t n3 = recv_reply(client, reg3, sizeof(reg3));
    ASSERT_EQ(n3, 32) << "REG3 is a 2-byte frame padded to 32 bytes on the wire";
    EXPECT_EQ(wire_type(reg3, n3), SRTLA_TYPE_REG3);

    ASSERT_EQ(registry_.groups().size(), 1u);
    EXPECT_EQ(registry_.groups()[0]->connections().size(), 1u)
        << "REG2 must add one connection to the group";
}

// --- Transition 8: REG3 completes -> connection is active ------------------

TEST_F(RegHandshakeTest, FullHandshakeLeavesConnectionActive) {
    int client = make_client();
    send_frame(client, build_reg_frame(SRTLA_TYPE_REG1, make_client_id(0x44)));
    ASSERT_EQ(pump(kBaseTs), 1);

    uint8_t reg2[512];
    ASSERT_EQ(recv_reply(client, reg2, sizeof(reg2)), SRTLA_TYPE_REG2_LEN);
    std::array<uint8_t, SRTLA_ID_LEN> full_id {};
    std::memcpy(full_id.data(), reg2 + 2, SRTLA_ID_LEN);

    send_frame(client, build_reg_frame(SRTLA_TYPE_REG2, full_id));
    ASSERT_EQ(pump(kBaseTs), 1);

    uint8_t reg3[64];
    ASSERT_EQ(recv_reply(client, reg3, sizeof(reg3)), 32);

    ASSERT_EQ(registry_.groups().size(), 1u);
    auto &conns = registry_.groups()[0]->connections();
    ASSERT_EQ(conns.size(), 1u);
    // "Active" = registered, freshly stamped, not in recovery.
    EXPECT_EQ(conns[0]->last_received(), kBaseTs);
    EXPECT_EQ(conns[0]->recovery_start(), 0);
}

// --- Multi-link: a second sender joins an existing group -------------------

TEST_F(RegHandshakeTest, Reg2FromNewAddressAddsSecondConnection) {
    int client1 = make_client();
    send_frame(client1, build_reg_frame(SRTLA_TYPE_REG1, make_client_id(0x55)));
    ASSERT_EQ(pump(), 1);
    uint8_t reg2[512];
    ASSERT_EQ(recv_reply(client1, reg2, sizeof(reg2)), SRTLA_TYPE_REG2_LEN);
    std::array<uint8_t, SRTLA_ID_LEN> full_id {};
    std::memcpy(full_id.data(), reg2 + 2, SRTLA_ID_LEN);

    // First link completes.
    send_frame(client1, build_reg_frame(SRTLA_TYPE_REG2, full_id));
    ASSERT_EQ(pump(), 1);
    uint8_t reg3a[64];
    ASSERT_EQ(recv_reply(client1, reg3a, sizeof(reg3a)), 32);

    // Second link presents the SAME full_id from a different source address.
    int client2 = make_client();
    send_frame(client2, build_reg_frame(SRTLA_TYPE_REG2, full_id));
    ASSERT_EQ(pump(), 1);
    uint8_t reg3b[64];
    ssize_t n = recv_reply(client2, reg3b, sizeof(reg3b));
    ASSERT_EQ(n, 32);
    EXPECT_EQ(wire_type(reg3b, n), SRTLA_TYPE_REG3);

    ASSERT_EQ(registry_.groups().size(), 1u);
    EXPECT_EQ(registry_.groups()[0]->connections().size(), 2u)
        << "second link must bond into the same group";
}

// --- Transition 4: REG2 with an unknown group id -> exactly one REG_NGP -----

TEST_F(RegHandshakeTest, Reg2UnknownGroupSendsExactlyOneNgpAndCreatesNoGroup) {
    int client = make_client();
    // Never-registered id.
    send_frame(client, build_reg_frame(SRTLA_TYPE_REG2, make_client_id(0x66)));
    ASSERT_EQ(pump(), 1);

    uint8_t reply[64];
    ssize_t n = recv_reply(client, reply, sizeof(reply));
    ASSERT_EQ(n, 32) << "REG_NGP is a 2-byte frame padded to 32 bytes";
    EXPECT_EQ(wire_type(reply, n), SRTLA_TYPE_REG_NGP);

    EXPECT_EQ(registry_.groups().size(), 0u) << "unknown-group REG2 must not create a group";

    // Exactly one reply -- nothing else queued.
    uint8_t extra[64];
    ssize_t m = recv_reply(client, extra, sizeof(extra));
    EXPECT_EQ(m, -1) << "only a single REG_NGP must be emitted";
}

// --- Transition 7: REG2 with a wrong full_id is rejected (REG_NGP) ----------

TEST_F(RegHandshakeTest, Reg2WithWrongFullIdSendsNgp) {
    int client = make_client();
    send_frame(client, build_reg_frame(SRTLA_TYPE_REG1, make_client_id(0x77)));
    ASSERT_EQ(pump(), 1);
    uint8_t reg2[512];
    ASSERT_EQ(recv_reply(client, reg2, sizeof(reg2)), SRTLA_TYPE_REG2_LEN);

    // Corrupt the full_id so it matches no group.
    std::array<uint8_t, SRTLA_ID_LEN> bad_id {};
    std::memcpy(bad_id.data(), reg2 + 2, SRTLA_ID_LEN);
    bad_id[SRTLA_ID_LEN - 1] ^= 0xff;
    bad_id[0] ^= 0xff;

    send_frame(client, build_reg_frame(SRTLA_TYPE_REG2, bad_id));
    ASSERT_EQ(pump(), 1);

    uint8_t reply[64];
    ssize_t n = recv_reply(client, reply, sizeof(reply));
    ASSERT_EQ(n, 32);
    EXPECT_EQ(wire_type(reply, n), SRTLA_TYPE_REG_NGP)
        << "an unmatched full_id must be rejected with REG_NGP";

    ASSERT_EQ(registry_.groups().size(), 1u);
    EXPECT_EQ(registry_.groups()[0]->connections().size(), 0u)
        << "rejected REG2 must not add a connection";
}

// --- Duplicate REG1 from the same source: idempotent group, REG_ERR ---------

TEST_F(RegHandshakeTest, DuplicateReg1SameSourceKeepsSingleGroupAndRepliesRegErr) {
    int client = make_client();
    auto cid = make_client_id(0x88);

    send_frame(client, build_reg_frame(SRTLA_TYPE_REG1, cid));
    ASSERT_EQ(pump(), 1);
    uint8_t reg2[512];
    ASSERT_EQ(recv_reply(client, reg2, sizeof(reg2)), SRTLA_TYPE_REG2_LEN);
    ASSERT_EQ(registry_.groups().size(), 1u);

    // Same address registers again -> address-already-registered guard.
    send_frame(client, build_reg_frame(SRTLA_TYPE_REG1, cid));
    ASSERT_EQ(pump(), 1);

    uint8_t reply[64];
    ssize_t n = recv_reply(client, reply, sizeof(reply));
    ASSERT_EQ(n, 32) << "REG_ERR is a 2-byte frame padded to 32 bytes";
    EXPECT_EQ(wire_type(reply, n), SRTLA_TYPE_REG_ERR);

    EXPECT_EQ(registry_.groups().size(), 1u)
        << "a duplicate REG1 must not spawn a second group";
}

// --- Concurrent REG1 from the same sender in one batch -> single group ------

TEST_F(RegHandshakeTest, ConcurrentReg1SameSourceCreatesSingleGroup) {
    int client = make_client();
    auto cid = make_client_id(0x99);

    // Two REG1s queued before a single recvmmsg batch.
    send_frame(client, build_reg_frame(SRTLA_TYPE_REG1, cid));
    send_frame(client, build_reg_frame(SRTLA_TYPE_REG1, cid));
    int read = pump();
    EXPECT_EQ(read, 2) << "both REG1s should arrive in one batch";

    EXPECT_EQ(registry_.groups().size(), 1u)
        << "concurrent REG1 from one source must yield exactly one group";

    // First reply REG2, second reply REG_ERR (address already registered).
    uint8_t a[512];
    ssize_t na = recv_reply(client, a, sizeof(a));
    ASSERT_EQ(na, SRTLA_TYPE_REG2_LEN);
    EXPECT_EQ(wire_type(a, na), SRTLA_TYPE_REG2);

    uint8_t b[64];
    ssize_t nb = recv_reply(client, b, sizeof(b));
    ASSERT_EQ(nb, 32);
    EXPECT_EQ(wire_type(b, nb), SRTLA_TYPE_REG_ERR);
}

// --- REG_NAK (0x9212, CeraLive-only): receiver does not act on inbound ------
//
// REG_NAK is a CeraLive-only type the SENDER uses; the receiver has no
// inbound handler for it. A 2-byte 0x9212 frame is not REG1/2/3, matches no
// connection address, and is shorter than SRT_MIN_LEN -- so the handler
// drops it silently with no reply and no state change. This freezes that
// "ignored, never crashes" contract.
TEST_F(RegHandshakeTest, RegNakInboundIsIgnoredByReceiver) {
    int client = make_client();
    uint8_t nak[2];
    nak[0] = static_cast<uint8_t>((SRTLA_TYPE_REG_NAK >> 8) & 0xff);
    nak[1] = static_cast<uint8_t>(SRTLA_TYPE_REG_NAK & 0xff);
    auto dest = loopback_addr(srtla_port_);
    ASSERT_EQ(::sendto(client, nak, sizeof(nak), 0,
                       reinterpret_cast<const struct sockaddr *>(&dest), sizeof(dest)),
              static_cast<ssize_t>(sizeof(nak)));

    EXPECT_EQ(pump(), 1) << "the frame is read off the socket";
    EXPECT_EQ(registry_.groups().size(), 0u) << "REG_NAK must not create any group";

    uint8_t reply[64];
    EXPECT_EQ(recv_reply(client, reply, sizeof(reply)), -1)
        << "receiver must not reply to an inbound REG_NAK";
}

// --- Malformed REG1: wrong size is not a REG1 (silently ignored) -----------
//
// is_srtla_reg1() requires an exact 258-byte length. A short frame is not
// recognized as REG1, is not REG2/3, matches no address, and is dropped --
// the receiver deliberately stays silent for unrecognized garbage rather
// than emitting REG_ERR (which would let any stray UDP packet draw a reply).
TEST_F(RegHandshakeTest, MalformedReg1WrongSizeIsIgnored) {
    int client = make_client();
    std::vector<uint8_t> short_frame(100, 0);
    short_frame[0] = 0x92;
    short_frame[1] = 0x00; // REG1 magic, but wrong length
    send_frame(client, short_frame);

    EXPECT_EQ(pump(), 1);
    EXPECT_EQ(registry_.groups().size(), 0u) << "malformed REG1 must not create a group";

    uint8_t reply[64];
    EXPECT_EQ(recv_reply(client, reply, sizeof(reply)), -1)
        << "wrong-size REG1 draws no reply";
}

// --- Malformed REG1: right size, wrong magic (silently ignored) ------------

TEST_F(RegHandshakeTest, MalformedReg1BadMagicIsIgnored) {
    int client = make_client();
    auto cid = make_client_id(0xAB);
    // Correct 258-byte length but a non-REG type in the header.
    auto frame = build_reg_frame(0x9999, cid);
    send_frame(client, frame);

    EXPECT_EQ(pump(), 1);
    EXPECT_EQ(registry_.groups().size(), 0u) << "bad-magic frame must not create a group";

    uint8_t reply[64];
    EXPECT_EQ(recv_reply(client, reply, sizeof(reply)), -1)
        << "bad-magic frame draws no reply";
}

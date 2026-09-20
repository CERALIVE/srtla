/*
    srtla - SRT transport proxy with link aggregation
    Copyright (C) 2026 CeraLive

    Handler-level test harness for the SRTLA receiver registration path.

    SRTLAHandler::register_group / register_connection are private; the only
    public seam is process_packets(ts), which drains the receiver's UDP socket
    via recvmmsg(MSG_DONTWAIT) and replies (REG2 / REG3 / REG_ERR / REG_NGP)
    with pad_sendto. This harness therefore drives the real handler over a real
    loopback UDP socket pair:

        Client (bound ephemeral, connect()'d to recv_sock)
              --REG1/REG2-->  recv_sock  --process_packets()-->  SRTLAHandler
              <--REG2/REG3/REG_ERR/REG_NGP (pad_sendto)--

    Each Client binds its own ephemeral port so distinct clients present
    distinct source addresses (one srtla "connection" each). A fresh
    ConnectionRegistry per harness avoids the process-wide singleton, so tests
    are independent and order-free.

    Replies for control packets shorter than 32 bytes are zero-padded to 32
    bytes by pad_sendto; the first two bytes still carry the network-order type,
    so pkt_type() classifies every reply regardless of padding.
*/

#pragma once

#include <arpa/inet.h>
#include <endian.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <array>
#include <cstdint>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <vector>

#include "connection/connection_registry.h"
#include "protocol/srt_handler.h"
#include "protocol/srtla_handler.h"
#include "quality/metrics_collector.h"

extern "C" {
#include "common.h"
}

namespace srtla::test {

// 127.0.0.1:<port>, port 0 => kernel-assigned ephemeral.
inline struct sockaddr_storage loopback_addr(uint16_t port) {
    struct sockaddr_storage ss;
    std::memset(&ss, 0, sizeof(ss));
    auto *in = reinterpret_cast<struct sockaddr_in *>(&ss);
    in->sin_family = AF_INET;
    in->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    in->sin_port = htons(port);
    return ss;
}

// SRTLA / SRT 16-bit packet type, read from the first two (network-order) bytes.
inline uint16_t pkt_type(const std::vector<uint8_t> &buf) {
    if (buf.size() < 2) {
        return 0;
    }
    return static_cast<uint16_t>((static_cast<uint16_t>(buf[0]) << 8) | buf[1]);
}

// A deterministic 256-byte registration id whose first half (the only bytes the
// receiver copies for the group id) is unique per `seed`; second half left zero,
// matching a sender that has not yet learnt the receiver-completed id.
inline std::array<uint8_t, SRTLA_ID_LEN> make_client_id(uint32_t seed) {
    std::array<uint8_t, SRTLA_ID_LEN> id{};
    for (int i = 0; i < SRTLA_ID_LEN / 2; ++i) {
        id[static_cast<size_t>(i)] =
            static_cast<uint8_t>((seed * 2654435761u + static_cast<uint32_t>(i) * 40503u) & 0xffu);
    }
    return id;
}

// Pull the full (receiver-completed) 256-byte id out of a REG2 reply (258 bytes).
inline std::array<uint8_t, SRTLA_ID_LEN> extract_full_id(const std::vector<uint8_t> &reg2) {
    std::array<uint8_t, SRTLA_ID_LEN> id{};
    if (reg2.size() >= static_cast<size_t>(SRTLA_TYPE_REG2_LEN)) {
        std::memcpy(id.data(), reg2.data() + 2, SRTLA_ID_LEN);
    }
    return id;
}

// One emulated srtla_send link: its own UDP socket with a distinct source addr.
class Client {
public:
    explicit Client(const struct sockaddr_storage &recv_addr) {
        fd_ = ::socket(AF_INET, SOCK_DGRAM, 0);
        if (fd_ < 0) {
            throw std::runtime_error("Client: socket() failed");
        }
        struct sockaddr_storage bind_ss = loopback_addr(0);
        if (::bind(fd_, reinterpret_cast<struct sockaddr *>(&bind_ss), sizeof(struct sockaddr_in)) != 0) {
            ::close(fd_);
            throw std::runtime_error("Client: bind() failed");
        }
        if (::connect(fd_, reinterpret_cast<const struct sockaddr *>(&recv_addr), sizeof(struct sockaddr_in)) != 0) {
            ::close(fd_);
            throw std::runtime_error("Client: connect() failed");
        }
    }

    ~Client() {
        if (fd_ >= 0) {
            ::close(fd_);
        }
    }

    Client(const Client &) = delete;
    Client &operator=(const Client &) = delete;
    Client(Client &&o) noexcept : fd_(o.fd_) { o.fd_ = -1; }
    Client &operator=(Client &&o) noexcept {
        if (this != &o) {
            if (fd_ >= 0) {
                ::close(fd_);
            }
            fd_ = o.fd_;
            o.fd_ = -1;
        }
        return *this;
    }

    void send_reg1(const std::array<uint8_t, SRTLA_ID_LEN> &id256) const {
        uint8_t buf[SRTLA_TYPE_REG1_LEN];
        uint16_t type = htobe16(SRTLA_TYPE_REG1);
        std::memcpy(buf, &type, sizeof(type));
        std::memcpy(buf + sizeof(type), id256.data(), SRTLA_ID_LEN);
        (void)::send(fd_, buf, sizeof(buf), 0);
    }

    void send_reg2(const std::array<uint8_t, SRTLA_ID_LEN> &id256) const {
        uint8_t buf[SRTLA_TYPE_REG2_LEN];
        uint16_t type = htobe16(SRTLA_TYPE_REG2);
        std::memcpy(buf, &type, sizeof(type));
        std::memcpy(buf + sizeof(type), id256.data(), SRTLA_ID_LEN);
        (void)::send(fd_, buf, sizeof(buf), 0);
    }

    // Receive one datagram, waiting up to timeout_ms for it. Returns false if
    // none arrives in time. The handler replies via a synchronous pad_sendto on
    // loopback, so by the time pump() returns every reply is already queued —
    // hence draining uses timeout_ms = 0 (pure non-blocking poll) and never
    // blocks, while "expect a reply" call sites keep a small budget for safety.
    bool recv_one(std::vector<uint8_t> &out, int timeout_ms = 200) const {
        struct pollfd pfd {};
        pfd.fd = fd_;
        pfd.events = POLLIN;
        if (::poll(&pfd, 1, timeout_ms) <= 0) {
            out.clear();
            return false;
        }
        out.assign(2048, 0);
        ssize_t n = ::recv(fd_, out.data(), out.size(), MSG_DONTWAIT);
        if (n <= 0) {
            out.clear();
            return false;
        }
        out.resize(static_cast<size_t>(n));
        return true;
    }

    void drain() const {
        std::vector<uint8_t> tmp;
        while (recv_one(tmp, 0)) {
        }
    }

    int fd() const { return fd_; }

private:
    int fd_ = -1;
};

// Owns a real receiver UDP socket and a live SRTLAHandler bound to it.
// The SRTHandler / srt_addr / epoll are only exercised by the data-forwarding
// path, which the registration and keepalive tests never reach.
class HandlerHarness {
public:
    HandlerHarness() {
        recv_sock_ = ::socket(AF_INET, SOCK_DGRAM, 0);
        if (recv_sock_ < 0) {
            throw std::runtime_error("HandlerHarness: socket() failed");
        }
        struct sockaddr_storage bind_ss = loopback_addr(0);
        if (::bind(recv_sock_, reinterpret_cast<struct sockaddr *>(&bind_ss), sizeof(struct sockaddr_in)) != 0) {
            ::close(recv_sock_);
            throw std::runtime_error("HandlerHarness: bind() failed");
        }
        socklen_t al = sizeof(struct sockaddr_in);
        std::memset(&recv_addr_, 0, sizeof(recv_addr_));
        if (::getsockname(recv_sock_, reinterpret_cast<struct sockaddr *>(&recv_addr_), &al) != 0) {
            ::close(recv_sock_);
            throw std::runtime_error("HandlerHarness: getsockname() failed");
        }
        epoll_fd_ = ::epoll_create1(0);
        srt_addr_ = loopback_addr(9); // discard port; unused on the reg/keepalive paths
        srt_handler_ = std::make_unique<protocol::SRTHandler>(recv_sock_, srt_addr_, epoll_fd_, registry_, rate_limiter_);
        handler_ = std::make_unique<protocol::SRTLAHandler>(recv_sock_, registry_, *srt_handler_, metrics_, rate_limiter_);
    }

    ~HandlerHarness() {
        if (recv_sock_ >= 0) {
            ::close(recv_sock_);
        }
        if (epoll_fd_ >= 0) {
            ::close(epoll_fd_);
        }
    }

    HandlerHarness(const HandlerHarness &) = delete;
    HandlerHarness &operator=(const HandlerHarness &) = delete;

    // Process every datagram currently queued on the receiver socket.
    // Returns the total number of packets the handler consumed.
    int pump(time_t ts) {
        int total = 0;
        for (int i = 0; i < 1024; ++i) {
            int n = handler_->process_packets(ts);
            if (n <= 0) {
                break;
            }
            total += n;
        }
        return total;
    }

    Client make_client() { return Client(recv_addr_); }

    connection::ConnectionRegistry &registry() { return registry_; }
    const struct sockaddr_storage &recv_addr() const { return recv_addr_; }
    int recv_fd() const { return recv_sock_; }

private:
    int recv_sock_ = -1;
    int epoll_fd_ = -1;
    struct sockaddr_storage recv_addr_ {};
    struct sockaddr_storage srt_addr_ {};
    connection::ConnectionRegistry registry_;
    quality::MetricsCollector metrics_;
    utils::AuthRateLimiter rate_limiter_;
    std::unique_ptr<protocol::SRTHandler> srt_handler_;
    std::unique_ptr<protocol::SRTLAHandler> handler_;
};

// Per-reply-type tally for an emulated link across one or more pump rounds.
struct ReplyTally {
    int reg2 = 0;
    int reg3 = 0;
    int reg_err = 0;
    int reg_ngp = 0;
    int other = 0;

    void classify(const std::vector<uint8_t> &buf) {
        switch (pkt_type(buf)) {
        case SRTLA_TYPE_REG2: ++reg2; break;
        case SRTLA_TYPE_REG3: ++reg3; break;
        case SRTLA_TYPE_REG_ERR: ++reg_err; break;
        case SRTLA_TYPE_REG_NGP: ++reg_ngp; break;
        default: ++other; break;
        }
    }
};

inline void drain_into(const Client &c, ReplyTally &tally) {
    std::vector<uint8_t> buf;
    while (c.recv_one(buf, 0)) {
        tally.classify(buf);
    }
}

} // namespace srtla::test

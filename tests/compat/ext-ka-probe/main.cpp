// ext-ka-probe — SRTLA extended-keepalive conformance probe.
//
// Our production srtla_send only emits the bare 2-byte SRTLA keepalive, so an
// ours-x-ours media run never exercises the receiver's *extended* keepalive
// telemetry path. This probe drives that path honestly: it performs a real
// SRTLA registration handshake (REG1 -> REG2 -> REG3) against srtla_rec and
// then sends genuine 38-byte extended keepalives carrying connection_info_t
// telemetry, exactly per the wire format in src/common.{h,c}:
//
//   bytes  0- 1  type   0x9000 (SRTLA_TYPE_KEEPALIVE), big-endian
//   bytes 10-11  magic  0xC01F (SRTLA_KEEPALIVE_MAGIC),  big-endian
//   bytes 12-13  ver    0x0001 (SRTLA_KEEPALIVE_EXT_VERSION)
//   bytes 14-37  connection_info_t {conn_id,window,in_flight,rtt,nak,bitrate}
//
// The receiver parses this, logs "Per-connection keepalive", and sets
// sender_supports_extended_keepalives=true. The harness greps the receiver log
// for that line to confirm extended-KA activation for the ours-x-ours pair.
//
// This is a test helper that speaks the SRTLA wire protocol directly; it has no
// libsrt dependency.

#include <arpa/inet.h>
#include <endian.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>

// Mirror of the protocol constants in src/common.h (kept local so the probe
// stays a standalone wire-format client with no srtla internal headers).
namespace {

constexpr uint16_t SRTLA_TYPE_KEEPALIVE = 0x9000;
constexpr uint16_t SRTLA_TYPE_REG1 = 0x9200;
constexpr uint16_t SRTLA_TYPE_REG2 = 0x9201;
constexpr uint16_t SRTLA_TYPE_REG3 = 0x9202;
constexpr uint16_t SRTLA_KEEPALIVE_MAGIC = 0xC01F;
constexpr uint16_t SRTLA_KEEPALIVE_EXT_VERSION = 0x0001;
constexpr int SRTLA_ID_LEN = 256;
constexpr int REG1_LEN = 2 + SRTLA_ID_LEN;
constexpr int REG2_LEN = 2 + SRTLA_ID_LEN;
constexpr int KEEPALIVE_EXT_LEN = 38;

struct Options {
  std::string host = "127.0.0.1";
  int port = 5000;
  int count = 5;     // extended keepalives to send
  int timeout_ms = 2000;
};

void usage(const char *a0) {
  std::fprintf(stderr,
               "usage: %s [--host H] [--port P] [--count N] [--timeout MS]\n",
               a0);
}

bool parse_args(int argc, char **argv, Options &o) {
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    auto val = [&](const char *n) -> const char * {
      if (i + 1 >= argc) {
        std::fprintf(stderr, "ext-ka-probe: %s needs a value\n", n);
        return nullptr;
      }
      return argv[++i];
    };
    if (a == "--host") {
      const char *v = val("--host"); if (!v) return false; o.host = v;
    } else if (a == "--port") {
      const char *v = val("--port"); if (!v) return false; o.port = std::atoi(v);
    } else if (a == "--count") {
      const char *v = val("--count"); if (!v) return false; o.count = std::atoi(v);
    } else if (a == "--timeout") {
      const char *v = val("--timeout"); if (!v) return false; o.timeout_ms = std::atoi(v);
    } else if (a == "-h" || a == "--help") {
      usage(argv[0]); std::exit(0);
    } else {
      std::fprintf(stderr, "ext-ka-probe: unknown arg '%s'\n", a.c_str());
      return false;
    }
  }
  if (o.port <= 0 || o.port > 65535) {
    std::fprintf(stderr, "ext-ka-probe: invalid --port\n");
    return false;
  }
  if (o.count < 1) o.count = 1;
  return true;
}

void put_be16(uint8_t *p, uint16_t v) {
  uint16_t b = htobe16(v);
  std::memcpy(p, &b, 2);
}
void put_be32(uint8_t *p, uint32_t v) {
  uint32_t b = htobe32(v);
  std::memcpy(p, &b, 4);
}
uint16_t get_be16(const uint8_t *p) {
  uint16_t v = 0;
  std::memcpy(&v, p, 2);
  return be16toh(v);
}

ssize_t recv_with_timeout(int fd, uint8_t *buf, size_t len, int timeout_ms) {
  struct timeval tv {};
  tv.tv_sec = timeout_ms / 1000;
  tv.tv_usec = static_cast<suseconds_t>(timeout_ms % 1000) * 1000;
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  return recv(fd, buf, len, 0);
}

} // namespace

int main(int argc, char **argv) {
  Options o;
  if (!parse_args(argc, argv, o)) {
    usage(argv[0]);
    return 2;
  }

  int fd = socket(AF_INET, SOCK_DGRAM, 0);
  if (fd < 0) {
    std::perror("ext-ka-probe: socket");
    return 1;
  }

  struct sockaddr_in dst {};
  dst.sin_family = AF_INET;
  dst.sin_port = htons(static_cast<uint16_t>(o.port));
  if (inet_pton(AF_INET, o.host.c_str(), &dst.sin_addr) != 1) {
    // Allow hostnames too.
    struct addrinfo hints {}, *res = nullptr;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    if (getaddrinfo(o.host.c_str(), nullptr, &hints, &res) != 0 || !res) {
      std::fprintf(stderr, "ext-ka-probe: cannot resolve '%s'\n", o.host.c_str());
      close(fd);
      return 1;
    }
    dst.sin_addr =
        reinterpret_cast<struct sockaddr_in *>(res->ai_addr)->sin_addr;
    freeaddrinfo(res);
  }

  if (connect(fd, reinterpret_cast<sockaddr *>(&dst), sizeof(dst)) != 0) {
    std::perror("ext-ka-probe: connect");
    close(fd);
    return 1;
  }

  // ---- REG1: announce a new group (first 128 ID bytes are the sender half) --
  uint8_t reg1[REG1_LEN];
  std::memset(reg1, 0, sizeof(reg1));
  put_be16(reg1, SRTLA_TYPE_REG1);
  // Fill the sender half of the ID with non-zero pseudo-random bytes.
  unsigned seed = static_cast<unsigned>(getpid()) ^
                  static_cast<unsigned>(time(nullptr));
  for (int i = 0; i < SRTLA_ID_LEN / 2; ++i) {
    seed = (seed * 1103515245U) + 12345U;
    reg1[2 + i] = static_cast<uint8_t>((seed >> 16) & 0xFF);
  }
  if (send(fd, reg1, sizeof(reg1), 0) != static_cast<ssize_t>(sizeof(reg1))) {
    std::perror("ext-ka-probe: send REG1");
    close(fd);
    return 1;
  }

  uint8_t in[1500];
  ssize_t r = recv_with_timeout(fd, in, sizeof(in), o.timeout_ms);
  if (r < REG2_LEN || get_be16(in) != SRTLA_TYPE_REG2) {
    std::fprintf(stderr,
                 "ext-ka-probe: expected REG2 (%d bytes, type 0x9201), "
                 "got %zd bytes type 0x%04x\n",
                 REG2_LEN, r, r >= 2 ? get_be16(in) : 0);
    close(fd);
    return 1;
  }
  // The full group ID returned by the receiver (its half filled in).
  uint8_t group_id[SRTLA_ID_LEN];
  std::memcpy(group_id, in + 2, SRTLA_ID_LEN);

  // ---- REG2: register this connection against the returned group ID ---------
  uint8_t reg2[REG2_LEN];
  put_be16(reg2, SRTLA_TYPE_REG2);
  std::memcpy(reg2 + 2, group_id, SRTLA_ID_LEN);
  if (send(fd, reg2, sizeof(reg2), 0) != static_cast<ssize_t>(sizeof(reg2))) {
    std::perror("ext-ka-probe: send REG2");
    close(fd);
    return 1;
  }

  r = recv_with_timeout(fd, in, sizeof(in), o.timeout_ms);
  if (r < 2 || get_be16(in) != SRTLA_TYPE_REG3) {
    std::fprintf(stderr,
                 "ext-ka-probe: expected REG3 (type 0x9202), got %zd bytes "
                 "type 0x%04x\n",
                 r, r >= 2 ? get_be16(in) : 0);
    close(fd);
    return 1;
  }
  std::fprintf(stderr, "ext-ka-probe: registered with %s:%d\n", o.host.c_str(),
               o.port);

  // ---- Extended keepalives with connection_info_t telemetry -----------------
  uint8_t ka[KEEPALIVE_EXT_LEN];
  std::memset(ka, 0, sizeof(ka));
  put_be16(ka + 0, SRTLA_TYPE_KEEPALIVE);       // type
  put_be16(ka + 10, SRTLA_KEEPALIVE_MAGIC);     // magic @ 10-11
  put_be16(ka + 12, SRTLA_KEEPALIVE_EXT_VERSION); // version @ 12-13
  put_be32(ka + 14, 0);        // conn_id
  put_be32(ka + 18, 8192);     // window
  put_be32(ka + 22, 100);      // in_flight
  put_be32(ka + 26, 30);       // rtt_ms
  put_be32(ka + 30, 2);        // nak_count
  put_be32(ka + 34, 250000);   // bitrate_bytes_per_sec (~2000 kbit/s)

  int sent = 0;
  for (int i = 0; i < o.count; ++i) {
    if (send(fd, ka, sizeof(ka), 0) == static_cast<ssize_t>(sizeof(ka))) {
      ++sent;
    } else {
      std::perror("ext-ka-probe: send keepalive");
    }
    usleep(200 * 1000); // 200ms between keepalives
    // Drain any echoed keepalive so the socket buffer stays clear.
    struct timeval z {0, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &z, sizeof(z));
    while (recv(fd, in, sizeof(in), MSG_DONTWAIT) > 0) {
    }
  }

  std::fprintf(stderr, "ext-ka-probe: sent %d extended keepalive(s)\n", sent);
  close(fd);
  return sent > 0 ? 0 : 1;
}

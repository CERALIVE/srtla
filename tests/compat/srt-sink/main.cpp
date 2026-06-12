// srt-sink — minimal libsrt listener for the SRTLA compatibility harness.
//
// Accepts a single SRT caller (the media stream relayed end-to-end through
// srtla_send -> srtla_rec), counts the application bytes it delivers, and on
// exit writes a JSON result file the harness consumes:
//
//   {"bytes_received": N, "first_byte_ms": M, "disconnects": D, "duration_ms": T}
//
//   bytes_received  total SRT payload bytes delivered by srt_recv
//   first_byte_ms   ms from sink start to the first delivered byte (-1 if none)
//   disconnects     times an accepted connection broke mid-run (teardown excluded)
//   duration_ms     ms the sink was alive (start -> exit)
//
// It exits 0 on SIGTERM/SIGINT (clean teardown) or when --duration elapses, and
// always flushes the JSON result first. This is a test helper, not production
// code: it links the system libsrt that srtla already depends on at runtime.

#include <srt/srt.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <signal.h>
#include <sys/socket.h>

#include <cerrno>
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>

namespace {

volatile sig_atomic_t g_stop = 0;

void on_signal(int) { g_stop = 1; }

uint64_t now_ms() {
  struct timespec ts {};
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (static_cast<uint64_t>(ts.tv_sec) * 1000ULL) +
         (static_cast<uint64_t>(ts.tv_nsec) / 1000000ULL);
}

struct Options {
  int port = 4001;
  std::string host = "0.0.0.0";
  std::string result_path;
  int latency_ms = 200;
  int64_t duration_ms = 0;
  int nakreport = -1;
  int lossmaxttl = -1;
};

void usage(const char *argv0) {
  std::fprintf(stderr,
               "usage: %s --port P --result FILE [--host H] [--latency MS] "
               "[--duration SEC] [--nakreport 0|1] [--lossmaxttl N]\n",
               argv0);
}

bool parse_args(int argc, char **argv, Options &opt) {
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    auto need = [&](const char *name) -> const char * {
      if (i + 1 >= argc) {
        std::fprintf(stderr, "srt-sink: %s requires a value\n", name);
        return nullptr;
      }
      return argv[++i];
    };
    if (a == "--port") {
      const char *v = need("--port");
      if (!v) return false;
      opt.port = std::atoi(v);
    } else if (a == "--host") {
      const char *v = need("--host");
      if (!v) return false;
      opt.host = v;
    } else if (a == "--result") {
      const char *v = need("--result");
      if (!v) return false;
      opt.result_path = v;
    } else if (a == "--latency") {
      const char *v = need("--latency");
      if (!v) return false;
      opt.latency_ms = std::atoi(v);
    } else if (a == "--duration") {
      const char *v = need("--duration");
      if (!v) return false;
      opt.duration_ms = static_cast<int64_t>(std::atof(v) * 1000.0);
    } else if (a == "--nakreport") {
      const char *v = need("--nakreport");
      if (!v) return false;
      opt.nakreport = std::atoi(v);
      if (opt.nakreport != 0 && opt.nakreport != 1) {
        std::fprintf(stderr, "srt-sink: --nakreport must be 0 or 1\n");
        return false;
      }
    } else if (a == "--lossmaxttl") {
      const char *v = need("--lossmaxttl");
      if (!v) return false;
      opt.lossmaxttl = std::atoi(v);
      if (opt.lossmaxttl < 0) {
        std::fprintf(stderr, "srt-sink: --lossmaxttl must be non-negative\n");
        return false;
      }
    } else if (a == "-h" || a == "--help") {
      usage(argv[0]);
      std::exit(0);
    } else {
      std::fprintf(stderr, "srt-sink: unknown argument '%s'\n", a.c_str());
      return false;
    }
  }
  if (opt.port <= 0 || opt.port > 65535) {
    std::fprintf(stderr, "srt-sink: invalid --port\n");
    return false;
  }
  if (opt.result_path.empty()) {
    std::fprintf(stderr, "srt-sink: --result is required\n");
    return false;
  }
  return true;
}

// Atomic-ish write: temp file + rename so a reader never sees a partial JSON.
bool write_result(const std::string &path, uint64_t bytes_received,
                  int64_t first_byte_ms, int disconnects, uint64_t duration_ms) {
  std::string tmp = path + ".tmp";
  FILE *f = std::fopen(tmp.c_str(), "w");
  if (!f) {
    std::fprintf(stderr, "srt-sink: cannot open %s: %s\n", tmp.c_str(),
                 std::strerror(errno));
    return false;
  }
  std::fprintf(f,
               "{\"bytes_received\": %" PRIu64 ", \"first_byte_ms\": %" PRId64
               ", \"disconnects\": %d, \"duration_ms\": %" PRIu64 "}\n",
               bytes_received, first_byte_ms, disconnects, duration_ms);
  std::fflush(f);
  std::fclose(f);
  if (std::rename(tmp.c_str(), path.c_str()) != 0) {
    std::fprintf(stderr, "srt-sink: cannot rename %s -> %s: %s\n", tmp.c_str(),
                 path.c_str(), std::strerror(errno));
    return false;
  }
  return true;
}

} // namespace

int main(int argc, char **argv) {
  Options opt;
  if (!parse_args(argc, argv, opt)) {
    usage(argv[0]);
    return 2;
  }

  signal(SIGTERM, on_signal);
  signal(SIGINT, on_signal);
  signal(SIGPIPE, SIG_IGN);

  const uint64_t start_ms = now_ms();
  uint64_t bytes_received = 0;
  int64_t first_byte_ms = -1;
  int disconnects = 0;

  // Best-effort result on any early return so the harness always finds a file.
  auto flush = [&]() {
    write_result(opt.result_path, bytes_received, first_byte_ms, disconnects,
                 now_ms() - start_ms);
  };

  if (srt_startup() < 0) {
    std::fprintf(stderr, "srt-sink: srt_startup failed: %s\n", srt_getlasterror_str());
    flush();
    return 1;
  }

  SRTSOCKET listener = srt_create_socket();
  if (listener == SRT_INVALID_SOCK) {
    std::fprintf(stderr, "srt-sink: srt_create_socket failed: %s\n", srt_getlasterror_str());
    srt_cleanup();
    flush();
    return 1;
  }

  int live = SRTT_LIVE;
  srt_setsockflag(listener, SRTO_TRANSTYPE, &live, sizeof(live));
  int no = 0;
  srt_setsockflag(listener, SRTO_RCVSYN, &no, sizeof(no)); // non-blocking accept
  srt_setsockflag(listener, SRTO_RCVLATENCY, &opt.latency_ms, sizeof(opt.latency_ms));

  // Apply optional libsrt evaluation flags
  if (opt.nakreport >= 0) {
    srt_setsockflag(listener, SRTO_NAKREPORT, &opt.nakreport, sizeof(opt.nakreport));
  }
  if (opt.lossmaxttl >= 0) {
    srt_setsockflag(listener, SRTO_LOSSMAXTTL, &opt.lossmaxttl, sizeof(opt.lossmaxttl));
  }

  struct sockaddr_in sa {};
  sa.sin_family = AF_INET;
  sa.sin_port = htons(static_cast<uint16_t>(opt.port));
  if (inet_pton(AF_INET, opt.host.c_str(), &sa.sin_addr) != 1) {
    std::fprintf(stderr, "srt-sink: invalid --host '%s'\n", opt.host.c_str());
    srt_close(listener);
    srt_cleanup();
    flush();
    return 1;
  }

  if (srt_bind(listener, reinterpret_cast<sockaddr *>(&sa), sizeof(sa)) ==
      SRT_ERROR) {
    std::fprintf(stderr, "srt-sink: srt_bind :%d failed: %s\n", opt.port,
                 srt_getlasterror_str());
    srt_close(listener);
    srt_cleanup();
    flush();
    return 1;
  }
  if (srt_listen(listener, 1) == SRT_ERROR) {
    std::fprintf(stderr, "srt-sink: srt_listen failed: %s\n", srt_getlasterror_str());
    srt_close(listener);
    srt_cleanup();
    flush();
    return 1;
  }

  int eid = srt_epoll_create();
  int ev_in = SRT_EPOLL_IN | SRT_EPOLL_ERR;
  srt_epoll_add_usock(eid, listener, &ev_in);

  // Print startup banner with libsrt version and effective option values
  uint32_t srt_version = srt_getversion();
  uint32_t major = (srt_version >> 24) & 0xFF;
  uint32_t minor = (srt_version >> 16) & 0xFF;
  uint32_t patch = (srt_version >> 8) & 0xFF;
  std::fprintf(stderr, "srt-sink: libsrt version %u.%u.%u\n", major, minor, patch);
  std::fprintf(stderr, "srt-sink: nakreport=%s lossmaxttl=%s\n",
               opt.nakreport < 0 ? "default" : (opt.nakreport ? "on" : "off"),
               opt.lossmaxttl < 0 ? "default" : std::to_string(opt.lossmaxttl).c_str());
  std::fprintf(stderr, "srt-sink: listening on %s:%d (latency %dms)\n",
               opt.host.c_str(), opt.port, opt.latency_ms);

  SRTSOCKET client = SRT_INVALID_SOCK;
  char buf[1500];

  while (!g_stop) {
    if (opt.duration_ms > 0 &&
        static_cast<int64_t>(now_ms() - start_ms) >= opt.duration_ms) {
      break;
    }

    SRT_EPOLL_EVENT events[8];
    int n = srt_epoll_uwait(eid, events, 8, 200);
    if (n < 0) {
      // Spurious wake or interrupted wait; loop and re-check stop/timeout.
      continue;
    }

    for (int i = 0; i < n; ++i) {
      SRTSOCKET s = events[i].fd;
      int what = events[i].events;

      if (s == listener) {
        SRTSOCKET in = srt_accept(listener, nullptr, nullptr);
        if (in == SRT_INVALID_SOCK) continue;
        if (client != SRT_INVALID_SOCK) {
          // Only one stream is expected; reject extras.
          srt_close(in);
          continue;
        }
        client = in;
        int cno = 0;
        srt_setsockflag(client, SRTO_RCVSYN, &cno, sizeof(cno));
        int cev = SRT_EPOLL_IN | SRT_EPOLL_ERR;
        srt_epoll_add_usock(eid, client, &cev);
        std::fprintf(stderr, "srt-sink: accepted SRT caller\n");
        continue;
      }

      if (s != client) continue;

      if (what & SRT_EPOLL_ERR) {
        if (!g_stop) ++disconnects;
        srt_epoll_remove_usock(eid, client);
        srt_close(client);
        client = SRT_INVALID_SOCK;
        std::fprintf(stderr, "srt-sink: client error/disconnect\n");
        continue;
      }

      if (what & SRT_EPOLL_IN) {
        for (;;) {
          int r = srt_recv(client, buf, sizeof(buf));
          if (r > 0) {
            if (first_byte_ms < 0) {
              first_byte_ms = static_cast<int64_t>(now_ms() - start_ms);
            }
            bytes_received += static_cast<uint64_t>(r);
            continue; // drain everything ready before re-polling
          }
          if (r == 0) {
            if (!g_stop) ++disconnects;
            srt_epoll_remove_usock(eid, client);
            srt_close(client);
            client = SRT_INVALID_SOCK;
            std::fprintf(stderr, "srt-sink: client closed\n");
            break;
          }
          // r == SRT_ERROR
          int err = srt_getlasterror(nullptr);
          if (err == SRT_EASYNCRCV) break; // no more data right now
          if (!g_stop) ++disconnects;
          srt_epoll_remove_usock(eid, client);
          srt_close(client);
          client = SRT_INVALID_SOCK;
          std::fprintf(stderr, "srt-sink: recv error: %s\n",
                       srt_getlasterror_str());
          break;
        }
      }
    }
  }

  if (client != SRT_INVALID_SOCK) srt_close(client);
  srt_close(listener);
  srt_cleanup();

  const uint64_t duration_ms = now_ms() - start_ms;
  std::fprintf(stderr,
               "srt-sink: bytes=%" PRIu64 " first_byte_ms=%" PRId64
               " disconnects=%d duration_ms=%" PRIu64 "\n",
               bytes_received, first_byte_ms, disconnects, duration_ms);

  if (!write_result(opt.result_path, bytes_received, first_byte_ms, disconnects,
                    duration_ms)) {
    return 1;
  }
  return 0;
}

// srt-sink — minimal libsrt listener for the SRTLA compatibility harness.
//
// Accepts a single SRT caller (the media stream relayed end-to-end through
// srtla_send -> srtla_rec), counts the application bytes it delivers, inspects
// the MPEG-TS it carries, and on exit writes a JSON result file the harness
// consumes:
//
//   {"bytes_received": N, "first_byte_ms": M, "disconnects": D, "duration_ms": T,
//    "ts_packets": P, "ts_sync_errors": S, "ts_cc_errors": C,
//    "pkt_rcv_loss": L, "pkt_rcv_drop": D2, "pkt_retrans": R}
//
//   bytes_received  total SRT payload bytes delivered by srt_recv
//   first_byte_ms   ms from sink start to the first delivered byte (-1 if none)
//   disconnects     times an accepted connection broke mid-run (teardown excluded)
//   duration_ms     ms the sink was alive (start -> exit)
//   ts_packets      total 188-byte MPEG-TS packets seen in the payload
//   ts_sync_errors  TS packets whose sync byte != 0x47
//   ts_cc_errors    per-PID continuity-counter discontinuities (excludes null
//                   PID 0x1FFF and the adaptation-field discontinuity_indicator)
//   pkt_rcv_loss    SRT srt_bstats pktRcvLossTotal (cumulative, summed/conn)
//   pkt_rcv_drop    SRT srt_bstats pktRcvDropTotal (too-late-to-play drops)
//   pkt_retrans     SRT srt_bstats pktRetransTotal (retransmitted packets)
//
// The ts_* keys quantify transport-stream integrity (a spurious-retransmit or
// loss profile shows up as cc_errors + SRT loss/retrans counters); the existing
// keys are preserved unchanged so older harness readers keep working.
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

#include "ts_continuity.h"

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
  int retransmitalgo = -1;
};

// All counters the sink reports. The leading four are the original, frozen
// schema; the rest are additive MPEG-TS / SRT telemetry (Task 5).
struct Result {
  uint64_t bytes_received = 0;
  int64_t first_byte_ms = -1;
  int disconnects = 0;
  uint64_t duration_ms = 0;
  uint64_t ts_packets = 0;
  uint64_t ts_sync_errors = 0;
  uint64_t ts_cc_errors = 0;
  uint64_t pkt_rcv_loss = 0;
  uint64_t pkt_rcv_drop = 0;
  uint64_t pkt_retrans = 0;
};

void usage(const char *argv0) {
  std::fprintf(stderr,
               "usage: %s --port P --result FILE [--host H] [--latency MS] "
               "[--duration SEC] [--nakreport 0|1] [--lossmaxttl N] "
               "[--retransmitalgo 0|1]\n",
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
    } else if (a == "--retransmitalgo") {
      const char *v = need("--retransmitalgo");
      if (!v) return false;
      opt.retransmitalgo = std::atoi(v);
      if (opt.retransmitalgo != 0 && opt.retransmitalgo != 1) {
        std::fprintf(stderr, "srt-sink: --retransmitalgo must be 0 or 1\n");
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
// The four original keys lead and are byte-for-byte unchanged; the ts_*/pkt_*
// keys are appended (additive schema).
bool write_result(const std::string &path, const Result &r) {
  std::string tmp = path + ".tmp";
  FILE *f = std::fopen(tmp.c_str(), "w");
  if (!f) {
    std::fprintf(stderr, "srt-sink: cannot open %s: %s\n", tmp.c_str(),
                 std::strerror(errno));
    return false;
  }
  std::fprintf(f,
               "{\"bytes_received\": %" PRIu64 ", \"first_byte_ms\": %" PRId64
               ", \"disconnects\": %d, \"duration_ms\": %" PRIu64
               ", \"ts_packets\": %" PRIu64 ", \"ts_sync_errors\": %" PRIu64
               ", \"ts_cc_errors\": %" PRIu64 ", \"pkt_rcv_loss\": %" PRIu64
               ", \"pkt_rcv_drop\": %" PRIu64 ", \"pkt_retrans\": %" PRIu64
               "}\n",
               r.bytes_received, r.first_byte_ms, r.disconnects, r.duration_ms,
               r.ts_packets, r.ts_sync_errors, r.ts_cc_errors, r.pkt_rcv_loss,
               r.pkt_rcv_drop, r.pkt_retrans);
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
  Result res;
  tscont::Tracker ts;

  // Snapshot a data socket's SRT loss/retrans counters into the running totals
  // just before it is closed (cumulative *Total fields, summed across any
  // reconnect). Best-effort: a fully torn-down socket may refuse srt_bstats.
  auto accumulate_stats = [&](SRTSOCKET s) {
    if (s == SRT_INVALID_SOCK) return;
    SRT_TRACEBSTATS perf;
    std::memset(&perf, 0, sizeof(perf));
    if (srt_bstats(s, &perf, 0) != 0) return;
    auto nn = [](int v) -> uint64_t {
      return v > 0 ? static_cast<uint64_t>(v) : 0;
    };
    res.pkt_rcv_loss += nn(perf.pktRcvLossTotal);
    res.pkt_rcv_drop += nn(perf.pktRcvDropTotal);
    res.pkt_retrans += nn(perf.pktRetransTotal);
  };

  // Copy the live TS counters into res and write the JSON. Used by the
  // early-return flush below and by the normal exit path.
  auto publish = [&](uint64_t dur_ms) -> bool {
    res.duration_ms = dur_ms;
    res.ts_packets = ts.packets();
    res.ts_sync_errors = ts.sync_errors();
    res.ts_cc_errors = ts.cc_errors();
    return write_result(opt.result_path, res);
  };

  // Best-effort result on any early return so the harness always finds a file.
  auto flush = [&]() { publish(now_ms() - start_ms); };

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

  // Apply optional libsrt evaluation flags. These are pre-bind options on the
  // listener and are inherited by the accepted data socket.
  if (opt.nakreport >= 0) {
    srt_setsockflag(listener, SRTO_NAKREPORT, &opt.nakreport, sizeof(opt.nakreport));
  }
  if (opt.lossmaxttl >= 0) {
    srt_setsockflag(listener, SRTO_LOSSMAXTTL, &opt.lossmaxttl, sizeof(opt.lossmaxttl));
  }
  if (opt.retransmitalgo >= 0) {
    srt_setsockflag(listener, SRTO_RETRANSMITALGO, &opt.retransmitalgo,
                    sizeof(opt.retransmitalgo));
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
  std::fprintf(stderr, "srt-sink: nakreport=%s lossmaxttl=%s retransmitalgo=%s\n",
               opt.nakreport < 0 ? "default" : (opt.nakreport ? "on" : "off"),
               opt.lossmaxttl < 0 ? "default" : std::to_string(opt.lossmaxttl).c_str(),
               opt.retransmitalgo < 0 ? "default"
                                      : std::to_string(opt.retransmitalgo).c_str());
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
        if (!g_stop) ++res.disconnects;
        accumulate_stats(client);
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
            if (res.first_byte_ms < 0) {
              res.first_byte_ms = static_cast<int64_t>(now_ms() - start_ms);
            }
            res.bytes_received += static_cast<uint64_t>(r);
            ts.feed(reinterpret_cast<const uint8_t *>(buf),
                    static_cast<size_t>(r));
            continue; // drain everything ready before re-polling
          }
          if (r == 0) {
            if (!g_stop) ++res.disconnects;
            accumulate_stats(client);
            srt_epoll_remove_usock(eid, client);
            srt_close(client);
            client = SRT_INVALID_SOCK;
            std::fprintf(stderr, "srt-sink: client closed\n");
            break;
          }
          // r == SRT_ERROR
          int err = srt_getlasterror(nullptr);
          if (err == SRT_EASYNCRCV) break; // no more data right now
          if (!g_stop) ++res.disconnects;
          accumulate_stats(client);
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

  if (client != SRT_INVALID_SOCK) {
    accumulate_stats(client);
    srt_close(client);
  }
  srt_close(listener);
  srt_cleanup();

  const uint64_t duration_ms = now_ms() - start_ms;
  res.duration_ms = duration_ms;
  res.ts_packets = ts.packets();
  res.ts_sync_errors = ts.sync_errors();
  res.ts_cc_errors = ts.cc_errors();
  std::fprintf(stderr,
               "srt-sink: bytes=%" PRIu64 " first_byte_ms=%" PRId64
               " disconnects=%d duration_ms=%" PRIu64 "\n",
               res.bytes_received, res.first_byte_ms, res.disconnects,
               duration_ms);
  std::fprintf(stderr,
               "srt-sink: ts_packets=%" PRIu64 " ts_sync_errors=%" PRIu64
               " ts_cc_errors=%" PRIu64 " pkt_rcv_loss=%" PRIu64
               " pkt_rcv_drop=%" PRIu64 " pkt_retrans=%" PRIu64 "\n",
               res.ts_packets, res.ts_sync_errors, res.ts_cc_errors,
               res.pkt_rcv_loss, res.pkt_rcv_drop, res.pkt_retrans);

  if (!write_result(opt.result_path, res)) {
    return 1;
  }
  return 0;
}

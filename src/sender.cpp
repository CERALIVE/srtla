/*
    srtla - SRT transport proxy with link aggregation, forked by IRLServer
    Copyright (C) 2020-2021 BELABOX project
    Copyright (C) 2025 IRLServer.com

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

#include <arpa/inet.h>
#include <assert.h>
#include <fstream>
#include <netdb.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "sd_notify.h"
#include "sender.h"
#include "sender_logic.h"
#include "sender_telemetry.h"
#include <argparse/argparse.hpp>

#include <string>
#include <vector>

using srtla::sender::HousekeepingAction;

#define PKT_LOG_SZ 256
#define REG2_TIMEOUT 4
#define REG3_TIMEOUT 4
#define GLOBAL_TIMEOUT 10

#define min(a, b) ((a < b) ? a : b)
#define max(a, b) ((a > b) ? a : b)
#define min_max(a, l, h) (max(min((a), (h)), (l)))

#define WINDOW_MIN 1
#define WINDOW_DEF 20
#define WINDOW_MAX 60
#define WINDOW_MULT 1000
#define WINDOW_DECR 100
#define WINDOW_INCR 30

#define LOG_PKT_INT 20

typedef struct conn {
  struct conn *next;
  int fd;
  time_t last_rcvd;
  time_t last_sent;
  struct sockaddr src;
  int removed;
  int in_flight_pkts;
  int window;
  int pkt_idx;
  int pkt_log[PKT_LOG_SZ];
  // Telemetry (ADR-001). Read/updated only on the --stats-file path; with the
  // flag absent these stay calloc-zeroed and untouched, so there is zero
  // behavioral footprint when telemetry is off.
  uint32_t tlm_id;         // stable per-link id, stringified as conn_id
  uint32_t tlm_nak_count;  // cumulative NAKs charged to this link
  uint64_t tlm_bytes_sent; // cumulative payload bytes forwarded on this link
  uint64_t tlm_last_bytes; // tlm_bytes_sent sampled at last emit (bitrate delta)
  uint64_t tlm_last_ms;    // wall-clock ms at last emit
} conn_t;

char *source_ip_file = NULL;

/*

Telemetry (ADR-001): opt-in via --stats-file <path>. Everything below is gated
on stats_file_enabled; when off, no stats file or temp sibling is ever opened,
renamed, or unlinked. The *_c buffers hold async-signal-safe copies of the live
and temp paths so the SIGTERM/SIGINT handler can unlink them on clean shutdown.

*/
bool stats_file_enabled = false;
std::string stats_file_path;
uint32_t next_tlm_id = 0;
static char stats_path_c[4096];
static char stats_path_tmp_c[4096 + 8];

int do_update_conns = 0;

struct addrinfo *addrs;

struct sockaddr srtla_addr, srt_addr;
const socklen_t addr_len = sizeof(srtla_addr);
conn_t *conns = NULL;
int listenfd;
int active_connections = 0;
int has_connected = 0;

conn_t *pending_reg2_conn = NULL;
time_t pending_reg_timeout = 0;

char srtla_id[SRTLA_ID_LEN];

/*

Async I/O support

*/
fd_set active_fds;
int max_act_fd = -1;

int add_active_fd(int fd) {
  if (fd < 0)
    return -1;

  if (fd > max_act_fd)
    max_act_fd = fd;
  FD_SET(fd, &active_fds);

  return 0;
}

int remove_active_fd(int fd) {
  if (fd < 0)
    return -1;

  FD_CLR(fd, &active_fds);

  return 0;
}

/*

srtla registration helpers

*/
int send_reg1(conn_t *c) {
  if (c->fd < 0)
    return -1;

  char buf[MTU];
  uint16_t packet_type = htobe16(SRTLA_TYPE_REG1);
  memcpy(buf, &packet_type, sizeof(packet_type));
  memcpy(buf + sizeof(packet_type), srtla_id, SRTLA_ID_LEN);

  int ret = sendto(c->fd, buf, SRTLA_TYPE_REG1_LEN, 0, &srtla_addr, addr_len);
  if (ret != SRTLA_TYPE_REG1_LEN)
    return -1;

  return 0;
}

int send_reg2(conn_t *c) {
  if (c->fd < 0)
    return -1;

  char buf[SRTLA_TYPE_REG2_LEN];
  uint16_t packet_type = htobe16(SRTLA_TYPE_REG2);
  memcpy(buf, &packet_type, sizeof(packet_type));
  memcpy(buf + sizeof(packet_type), srtla_id, SRTLA_ID_LEN);

  int ret = sendto(c->fd, buf, SRTLA_TYPE_REG2_LEN, 0, &srtla_addr, addr_len);
  return (ret == SRTLA_TYPE_REG2_LEN) ? 0 : -1;
}

/*

Handling code for packets coming from the SRT caller

*/
void reg_pkt(conn_t *c, int32_t packet) {
  spdlog::debug("{} ({}) register packet {} at idx {}", print_addr(&c->src),
                fmt::ptr(c), packet, c->pkt_idx);
  c->pkt_log[c->pkt_idx] = packet;
  c->pkt_idx++;
  c->pkt_idx %= PKT_LOG_SZ;

  c->in_flight_pkts++;
}

int conn_timed_out(conn_t *c, time_t ts) {
  /* Decision logic lives in sender_logic.h so it can be unit-tested without
     sockets/globals (regression guard for 906ac05: a never-received link,
     last_rcvd==0, is not-yet-established, not timed out). */
  return srtla::sender::conn_is_timed_out(c->last_rcvd, ts) ? 1 : 0;
}

conn_t *select_conn() {
  conn_t *min_c = NULL;
  int max_score = -1;
  int max_window = 0;

  for (conn_t *c = conns; c != NULL; c = c->next) {
    if (c->window > max_window) {
      max_window = c->window;
    }
  }

  time_t t;
  if (get_seconds(&t) != 0)
    return NULL;

  for (conn_t *c = conns; c != NULL; c = c->next) {
    /* If we have some very slow links, we may be better off ignoring them
       However, we'd probably need to periodically re-probe them, otherwise
       a link disabled due to a momentary glitch might not ever get enabled
       again unless all the remaining links suffered from high packet loss
       at some point. */
    /*if (c->window < max_window / 5) {
      c->window++;
      continue;
    }*/

    if (conn_timed_out(c, t)) {
      spdlog::debug("{} ({}): is timed out, ignoring it", print_addr(&c->src),
                    fmt::ptr(c));
      continue;
    }

    int score = c->window / (c->in_flight_pkts + 1);
    if (score > max_score) {
      min_c = c;
      max_score = score;
    }
  }

  if (min_c) {
    min_c->last_sent = t;
  }

  return min_c;
}

void handle_srt_data(int fd) {
  char buf[MTU];
  socklen_t len = sizeof(srt_addr);
  int n = recvfrom(fd, &buf, MTU, 0, &srt_addr, &len);

  conn_t *c = select_conn();
  if (c) {
    int32_t sn = get_srt_sn(buf, n);
    int ret = sendto(c->fd, &buf, n, 0, &srtla_addr, addr_len);
    if (ret == n) {
      if (stats_file_enabled) {
        c->tlm_bytes_sent += (uint64_t)n; // per-link throughput accounting
      }
      if (sn >= 0) {
        reg_pkt(c, sn);
      }
    } else {
      /* If sending the packet fails, adjust the timestamp to disable the link
         until a reconnection is confirmed. 1 so connection_housekeeping()
         prints its message.
         Rationale: fixes SenderFalselyDownsAliveLinkOnSubReceiverTimeoutGap
         (Task 9 case d) — this hard-failure path is the timeout-INDEPENDENT
         fast dead-link detector: an isolated / torn-down link fails sendto()
         immediately, so SENDER_CONN_TIMEOUT can match the receiver's 15 s
         window (sender_logic.h) without slowing real link-drop detection. */
      c->last_rcvd = 1;
      spdlog::error("{} ({}): sendto() failed, disabling the connection",
                    print_addr(&c->src), fmt::ptr(c));
    }
  }
}

/*

Handling code for packets coming from the receiver

*/
int get_pkt_idx(int idx, int increment) {
  idx = idx + increment;
  if (idx < 0)
    idx += PKT_LOG_SZ;
  idx %= PKT_LOG_SZ;
  assert(idx >= 0 && idx < PKT_LOG_SZ);
  return idx;
}

void register_nak(int32_t packet) {
  for (conn_t *c = conns; c != NULL; c = c->next) {
    int idx = get_pkt_idx(c->pkt_idx, -1);
    for (int i = idx; i != c->pkt_idx; i = get_pkt_idx(i, -1)) {
      if (c->pkt_log[i] == packet) {
        c->pkt_log[i] = -1;
        c->tlm_nak_count++; // attribute this NAK to the link that sent the pkt
        // It might be better to use exponential decay like this
        // c->window = c->window * 998 / 1000;
        c->window -= WINDOW_DECR;
        c->window = max(c->window, WINDOW_MIN * WINDOW_MULT);
        spdlog::debug("{} ({}): found NAKed packet {} in the log",
                      print_addr(&c->src), fmt::ptr(c), packet);
        return;
      }
    }
  }

  spdlog::debug("Didn't find NAKed packet {} in our logs", packet);
}

void register_srtla_ack(int32_t ack) {
  int found = 0;

  for (conn_t *c = conns; c != NULL; c = c->next) {
    int idx = get_pkt_idx(c->pkt_idx, -1);
    for (int i = idx; i != c->pkt_idx && !found; i = get_pkt_idx(i, -1)) {
      if (c->pkt_log[i] == ack) {
        found = 1;
        if (c->in_flight_pkts > 0) {
          c->in_flight_pkts--;
        }
        c->pkt_log[i] = -1;

        if (c->in_flight_pkts * WINDOW_MULT > c->window) {
          c->window += WINDOW_INCR - 1;
        }

        break;
      }
    }

    if (c->last_rcvd != 0) {
      c->window += 1;
      c->window = min(c->window, WINDOW_MAX * WINDOW_MULT);
    }
  }
}

/*
  TODO after the sequence number overflows, we should probably also mark high
  sn packets as received. However, this shouldn't normally be an issue as SRTLA
  ACKs acknowledge each packet individually. Also, if the SRTLA ACK is lost,
  stale entries will be overwritten soon enough as pkt_log is a circular buffer
*/
void conn_register_srt_ack(conn_t *c, int32_t ack) {
  int count = 0;
  int idx = get_pkt_idx(c->pkt_idx, -1);
  for (int i = idx; i != c->pkt_idx; i = get_pkt_idx(i, -1)) {
    if (c->pkt_log[i] < ack) {
      c->pkt_log[i] = -1;
    } else {
      count++;
    }
  }
  c->in_flight_pkts = count;
}

void register_srt_ack(int32_t ack) {
  for (conn_t *c = conns; c != NULL; c = c->next) {
    conn_register_srt_ack(c, ack);
  }
}

void handle_srtla_data(conn_t *c) {
  char buf[MTU];

  int n = recvfrom(c->fd, &buf, MTU, 0, NULL, NULL);
  if (n <= 0)
    return;

  time_t ts;
  get_seconds(&ts);

  uint16_t packet_type = get_srt_type(buf, n);

  /* Handling NGPs separately because we don't want them to update last_rcvd
     Otherwise they could be keeping failed connections marked active */
  if (packet_type == SRTLA_TYPE_REG_NGP) {
    /* Only process NGPs if:
     * we don't have any established connections
     * and we don't already have a pending REG1->REG2 exhange in flight
     * and we don't have any pending REG2->REG3 exchanges in flight
     */
    if (active_connections == 0 && pending_reg2_conn == NULL &&
        ts > pending_reg_timeout) {
      if (send_reg1(c) == 0) {
        pending_reg2_conn = c;
        pending_reg_timeout = ts + REG2_TIMEOUT;
      }
    }
    return;

  } else if (packet_type == SRTLA_TYPE_REG2) {
    if (pending_reg2_conn == c) {
      char *id = &buf[2];
      if (memcmp(id, srtla_id, SRTLA_ID_LEN / 2) != 0) {
        spdlog::error("{} ({}): got a mismatching ID in SRTLA_REG2",
                      print_addr(&c->src), fmt::ptr(c));
        return;
      }

      spdlog::info("{} ({}): connection group registered", print_addr(&c->src),
                   fmt::ptr(c));
      memcpy(srtla_id, id, SRTLA_ID_LEN);

      /* Broadcast REG2 */
      for (conn_t *i = conns; i != NULL; i = i->next) {
        send_reg2(i);
      }

      pending_reg2_conn = NULL;
      pending_reg_timeout = ts + REG3_TIMEOUT;
    }
    return;
  }

  c->last_rcvd = ts;

  switch (packet_type) {
  case SRT_TYPE_ACK: {
    uint32_t last_ack = *((uint32_t *)&buf[16]);
    last_ack = be32toh(last_ack);
    register_srt_ack(last_ack);
    break;
  }

  case SRT_TYPE_NAK: {
    uint32_t *ids = (uint32_t *)buf;
    for (int i = 4; i < n / 4; i++) {
      uint32_t id = be32toh(ids[i]);
      if (id & (1 << 31)) {
        id = id & 0x7FFFFFFF;
        uint32_t last_id = be32toh(ids[i + 1]);
        for (int32_t lost = id; lost <= last_id; lost++) {
          register_nak(lost);
        }
        i++;
      } else {
        register_nak(id);
      }
    }
    break;
  }

  // srtla packets below, don't send to SRT
  case SRTLA_TYPE_ACK: {
    uint32_t *acks = (uint32_t *)buf;
    for (int i = 1; i < n / 4; i++) {
      uint32_t id = be32toh(acks[i]);
      spdlog::debug("{} ({}): ack {}\n", print_addr(&c->src), fmt::ptr(c), id);
      register_srtla_ack(id);
    }
    return;
  }
  case SRTLA_TYPE_KEEPALIVE:
    spdlog::debug("{} ({}): got a keepalive", print_addr(&c->src), fmt::ptr(c));
    return; // don't send to SRT

  case SRTLA_TYPE_REG3:
    has_connected = 1;
    active_connections++;
    spdlog::info("{} ({}): connection established", print_addr(&c->src),
                 fmt::ptr(c));
    return;
  } // switch

  sendto(listenfd, &buf, n, 0, &srt_addr, addr_len);
}

/*

Connection and socket management

*/
conn_t *conn_find_by_src(struct sockaddr *src) {
  for (conn_t *c = conns; c != NULL; c = c->next) {
    if (memcmp(src, &c->src, sizeof(*src)) == 0) {
      return c;
    }
  }

  return NULL;
}

int setup_conns(char *source_ip_file) {
  FILE *config = fopen(source_ip_file, "r");
  if (config == NULL) {
    spdlog::critical("Failed to open the source ip file {}", source_ip_file);
    exit(EXIT_FAILURE);
  }

  int count = 0;
  char *line = NULL;
  size_t line_len = 0;
  while (getline(&line, &line_len, config) >= 0) {
    char *nl;
    if ((nl = strchr(line, '\n'))) {
      *nl = '\0';
    }

    struct sockaddr src;

    int ret = parse_ip((struct sockaddr_in *)&src, line);
    if (ret == 0) {
      conn_t *c = conn_find_by_src(&src);
      if (c == NULL) {
        conn_t *c = static_cast<conn_t *>(calloc(1, sizeof(conn_t)));
        assert(c != NULL);

        c->src = src;
        c->fd = -1;
        c->window = WINDOW_DEF * WINDOW_MULT;
        c->tlm_id = next_tlm_id++; // stable for the life of this link

        c->next = conns;
        conns = c;

        count++;

        spdlog::info("Added connection via {} ({})", print_addr(&c->src),
                     fmt::ptr(c));
      } else {
        c->removed = 0;
      }
    }
  }
  if (line)
    free(line);

  fclose(config);

  return count;
}

void update_conns(char *source_ip_file) {
  /* Refuse a SIGHUP reload that would yield zero valid source IPs (empty,
     garbage, or unreadable file). Without this guard every existing link would
     be marked removed and torn down, killing the stream — and setup_conns()
     would exit() on an unreadable file. Keep streaming on the current links. */
  if (!srtla::sender::reload_should_apply(
          srtla::sender::count_parseable_source_ips(source_ip_file))) {
    spdlog::error("Ignoring source IP reload from {}: no valid source IPs "
                  "(parse error); keeping existing connections",
                  source_ip_file);
    return;
  }

  for (conn_t *c = conns; c != NULL; c = c->next) {
    c->removed = 1;
  }

  setup_conns(source_ip_file);

  conn_t **prev = &conns;
  conn_t *next;
  for (conn_t *c = conns; c != NULL; c = next) {
    next = c->next;
    if (c->removed) {
      spdlog::info("Removed connection via {} ({})", print_addr(&c->src),
                   fmt::ptr(c));

      if (c == pending_reg2_conn) {
        pending_reg2_conn = NULL;
      }

      remove_active_fd(c->fd);
      close(c->fd);
      *prev = c->next;
      free(c);
    } else {
      prev = &c->next;
    }
  }
}

void schedule_update_conns(int signal) { do_update_conns = 1; }

/* Clean-shutdown handler installed only when --stats-file is active: remove the
   live stats file (and any stale temp sibling) so a stopped sender is "absent",
   not "stale". unlink() is async-signal-safe and the path buffers are filled
   once at startup and never mutated, so touching them from here is safe. */
void remove_stats_and_exit(int signal) {
  unlink(stats_path_c);
  unlink(stats_path_tmp_c);
  _exit(0);
}

int open_socket(conn_t *c, int quiet) {
  if (c->fd >= 0) {
    remove_active_fd(c->fd);
    close(c->fd);
    c->fd = -1;
  }

  // Set up the socket
  int fd = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK, 0);
  if (fd < 0) {
    spdlog::error("Failed to open a socket");
    return -1;
  }
  int bufsize = SEND_BUF_SIZE;
  int ret = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufsize, sizeof(bufsize));
  if (ret != 0) {
    spdlog::error("Failed to set send buffer size ({} bytes)", bufsize);
    goto err;
  }

  // Bind it to the source address
  ret = bind(fd, &c->src, sizeof(c->src));
  if (ret != 0) {
    if (!quiet) {
      spdlog::error("Failed to bind to the source address {}",
                    print_addr(&c->src));
    }
    goto err;
  }

  add_active_fd(fd);
  c->fd = fd;

  return 0;

err:
  close(fd);
  return -1;
}

int open_conns(const char *host, const char *port) {
  // Check that we can actually open & bind at least one socket
  int opened = 0;
  for (conn_t *c = conns; c != NULL; c = c->next) {
    if (open_socket(c, 0) == 0) {
      opened++;
    }
  }
  return opened;
}

/*

Connection housekeeping

*/
void set_srtla_addr(struct addrinfo *addr) {
  memcpy(&srtla_addr, addr->ai_addr, addr->ai_addrlen);
  spdlog::info("Trying to connect to {}...", print_addr(&srtla_addr));
}

void send_keepalive(conn_t *c) {
  spdlog::debug("{} ({}): sending keepalive", print_addr(&c->src), fmt::ptr(c));
  uint16_t pkt = htobe16(SRTLA_TYPE_KEEPALIVE);
  // ignoring the result on purpose
  sendto(c->fd, &pkt, sizeof(pkt), 0, &srtla_addr, addr_len);
}

/* Gather a telemetry snapshot for every *active* link and publish it atomically
   (ADR-001 Option A). Driven once per housekeeping tick (~1000 ms cadence). Zero
   active links still publishes "connections": [] with a fresh timestamp, so
   "running but idle" stays distinct from "absent". No-op unless --stats-file
   is set — when off, nothing here touches the filesystem. */
void emit_telemetry(time_t now_s, uint64_t now_ms) {
  if (!stats_file_enabled) {
    return;
  }

  std::vector<srtla::sender::TelemetrySnapshot> snaps;
  for (conn_t *c = conns; c != NULL; c = c->next) {
    if (c->fd < 0) {
      continue;
    }
    /* Only established links are "connections" — a never-registered or
       timed-out link is not an active uplink (mirrors active_connections). */
    if (srtla::sender::housekeeping_action(c->last_rcvd, now_s) !=
        HousekeepingAction::ActiveKeepalive) {
      continue;
    }

    srtla::sender::TelemetrySnapshot s;
    s.conn_id = c->tlm_id;
    s.rtt_ms = 0; // RTT is a receiver-side metric; the sender does not measure it
    s.nak_count = c->tlm_nak_count;
    s.weight_percent = srtla::sender::SENDER_DEFAULT_WEIGHT_PERCENT;
    s.window = c->window / WINDOW_MULT; // internal milli-packets -> packets
    s.in_flight = c->in_flight_pkts;

    /* Per-link bitrate from the byte delta since this link's last emit. The
       first emit has no baseline, so it reports 0 until the next tick. */
    uint64_t dbytes = c->tlm_bytes_sent - c->tlm_last_bytes;
    uint64_t dms = (c->tlm_last_ms != 0 && now_ms > c->tlm_last_ms)
                       ? (now_ms - c->tlm_last_ms)
                       : 0;
    s.bitrate_bytes_per_sec =
        (dms > 0) ? static_cast<uint32_t>((dbytes * 1000ULL) / dms) : 0;
    c->tlm_last_bytes = c->tlm_bytes_sent;
    c->tlm_last_ms = now_ms;

    snaps.push_back(s);
  }

  std::string json = srtla::sender::build_telemetry_json(now_ms, snaps);
  srtla::sender::write_telemetry_atomic(stats_file_path, json);
}

#define HOUSEKEEPING_INT 1000 // ms
void connection_housekeeping() {
  static uint64_t all_failed_at = 0;
  /* We use milliseconds here because with a seconds timer we may be
     resending a second REG2 very soon after the first one, depending
     on when the first execution happens within the seconds interval */
  static uint64_t last_ran = 0;
  uint64_t ms;
  if (get_ms(&ms) != 0)
    return;
  if ((last_ran + HOUSEKEEPING_INT) > ms)
    return;

  time_t time = (time_t)(ms / 1000);

  active_connections = 0;

  if (pending_reg2_conn && time > pending_reg_timeout) {
    pending_reg2_conn = NULL;
  }

  for (conn_t *c = conns; c != NULL; c = c->next) {
    if (c->fd < 0) {
      open_socket(c, 1);
      continue;
    }

    switch (srtla::sender::housekeeping_action(c->last_rcvd, time)) {
    case HousekeepingAction::TimedOutReconnect:
      /* When we first detect the connection having failed,
         we reset its status and print a message */
      spdlog::info("{} ({}): connection failed, attempting to reconnect",
                   print_addr(&c->src), fmt::ptr(c));
      c->last_rcvd = 0;
      c->last_sent = 0;
      c->window = WINDOW_MIN * WINDOW_MULT;
      c->in_flight_pkts = 0;
      for (int i = 0; i < PKT_LOG_SZ; i++) {
        c->pkt_log[i] = -1;
      }
      /* fall through: drive the same REG2/REG1 exchange as a fresh bootstrap.
         As the connection has timed out on our end, the receiver might have
         garbage collected it — try to re-establish rather than keepalive. */
      [[fallthrough]];

    case HousekeepingAction::BootstrapRegister:
      /* Never received anything yet (or just reset above): this connection is
         not registered. Drive the first REG2/REG1 exchange. */
      if (pending_reg2_conn == NULL) {
        send_reg2(c);
      } else if (pending_reg2_conn == c) {
        send_reg1(c);
      }
      continue;

    case HousekeepingAction::ActiveKeepalive:
      /* If a connection has received data in the last CONN_TIMEOUT seconds,
         then it's active */
      active_connections++;

      if (srtla::sender::keepalive_due(c->last_sent, time)) {
        send_keepalive(c);
      }
      break;
    }
  }

  if (active_connections == 0) {
    if (all_failed_at == 0) {
      all_failed_at = ms;
    }

    if (has_connected) {
      spdlog::error("warning: no available connections");
    }

    // Timeout when all connections have failed
    if (ms > (all_failed_at + (GLOBAL_TIMEOUT * 1000))) {
      if (has_connected) {
        spdlog::critical("Failed to re-establish any connections to {}",
                         print_addr(&srtla_addr));
        exit(EXIT_FAILURE);
      }

      spdlog::error("Failed to establish any initial connections to {}",
                    print_addr(&srtla_addr));

      // Walk through the list of resolved addresses
      if (addrs->ai_next) {
        addrs = addrs->ai_next;
        set_srtla_addr(addrs);
        all_failed_at = 0;
      } else {
        exit(EXIT_FAILURE);
      }
    }
  } else {
    all_failed_at = 0;
  }

  emit_telemetry(time, ms);

  last_ran = ms;
}

inline std::vector<char> get_random_bytes(size_t size) {
  std::vector<char> ret;
  ret.resize(size);

  std::ifstream f("/dev/urandom");
  if (!f.is_open()) {
    throw std::runtime_error("Failed to open /dev/urandom for random bytes");
  }

  f.read(ret.data(), size);
  if (f.gcount() != static_cast<std::streamsize>(size) || f.fail()) {
    f.close();
    throw std::runtime_error(
        "Failed to read sufficient random bytes from /dev/urandom");
  }
  f.close();

  return ret;
}

int main(int argc, char **argv) {
  argparse::ArgumentParser args("srtla_send", VERSION);
  // SRT_LISTEN_PORT SRTLA_HOST SRTLA_PORT BIND_IPS_FILE
  args.add_argument("listen_port")
      .help("Port to bind the SRT socket to")
      .default_value((uint16_t)5000)
      .scan<'d', uint16_t>();
  args.add_argument("srtla_host")
      .help("Hostname of the upstream SRTLA server")
      .default_value(std::string{"127.0.0.1"});
  args.add_argument("srtla_port")
      .help("Port of the upstream SRTLA server")
      .default_value((uint16_t)5001)
      .scan<'d', uint16_t>();
  args.add_argument("ips_file")
      .help("File containing the source IP addresses")
      .default_value(std::string{"/tmp/srtla_ips"});
  args.add_argument("--verbose")
      .help("Enable verbose logging")
      .default_value(false)
      .implicit_value(true);
  args.add_argument("--stats-file")
      .help("Write per-connection telemetry JSON to this path (atomic rename, "
            "~1s cadence). Telemetry is off when this flag is absent.")
      .default_value(std::string{});

  try {
    args.parse_args(argc, argv);
  } catch (const std::runtime_error &err) {
    std::cerr << err.what() << std::endl;
    std::cerr << args;
    std::exit(1);
  }
  if (args.get<bool>("--verbose"))
    spdlog::set_level(spdlog::level::debug);

  std::string stats_file = args.get<std::string>("--stats-file");
  if (!stats_file.empty()) {
    stats_file_enabled = true;
    stats_file_path = stats_file;
    snprintf(stats_path_c, sizeof(stats_path_c), "%s", stats_file_path.c_str());
    snprintf(stats_path_tmp_c, sizeof(stats_path_tmp_c), "%s.tmp",
             stats_file_path.c_str());
    spdlog::info("Telemetry enabled: writing per-connection stats to {}",
                 stats_file_path);
  }

  std::string ips_file = args.get<std::string>("ips_file");
  source_ip_file = (char *)ips_file.c_str();
  int conn_count = setup_conns(source_ip_file);
  if (conn_count <= 0) {
    spdlog::critical("Failed to parse any IP addresses in {}", source_ip_file);
    exit(EXIT_FAILURE);
  }

  struct sockaddr_in listen_addr;

  int port = args.get<uint16_t>("listen_port");

  // Read a random connection group id for this session
  auto random_bytes = get_random_bytes(SRTLA_ID_LEN / 2);
  std::memcpy(srtla_id, random_bytes.data(), SRTLA_ID_LEN / 2);

  FD_ZERO(&active_fds);

  listen_addr.sin_family = AF_INET;
  listen_addr.sin_addr.s_addr = INADDR_ANY;
  listen_addr.sin_port = htons(port);
  listenfd = socket(AF_INET, SOCK_DGRAM, 0);
  if (listenfd < 0) {
    spdlog::critical("Failed to create a socket");
    exit(EXIT_FAILURE);
  }

  int ret =
      bind(listenfd, (struct sockaddr *)&listen_addr, sizeof(listen_addr));
  if (ret < 0) {
    spdlog::critical("Failed to bind to port {}", port);
    exit(EXIT_FAILURE);
  }
  add_active_fd(listenfd);

  std::string srtla_host = args.get<std::string>("srtla_host");
  std::string srtla_port = std::to_string(args.get<uint16_t>("srtla_port"));
  int connected = open_conns(srtla_host.c_str(), srtla_port.c_str());
  if (connected < 1) {
    spdlog::critical("Failed to open and bind to any of the IP addresses in {}",
                     source_ip_file);
    exit(EXIT_FAILURE);
  }

  // Resolve the address of the receiver
  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_INET;
  hints.ai_socktype = SOCK_DGRAM;
  ret = getaddrinfo(srtla_host.c_str(), srtla_port.c_str(), &hints, &addrs);
  if (ret != 0) {
    spdlog::critical("Failed to resolve {}: {}", srtla_host, gai_strerror(ret));
    exit(EXIT_FAILURE);
  }

  set_srtla_addr(addrs);

  signal(SIGHUP, schedule_update_conns);
  if (stats_file_enabled) {
    signal(SIGTERM, remove_stats_and_exit);
    signal(SIGINT, remove_stats_and_exit);
  }

  int info_int = LOG_PKT_INT;

  /* Startup is complete: the listen socket is bound and at least one upstream
     connection is open. Tell systemd we are READY so a Type=notify unit leaves
     the "activating" state. No-op when not run under systemd. */
  sd_notify::ready();

  /* Pet the systemd watchdog (WatchdogSec=) from the main loop at half the
     configured interval. Reaching the top of the loop proves the bonding loop
     is still running; if it hangs/zombies the ping stops and systemd kills +
     respawns the process (ADR-0005). wd_interval_ms == 0 disables petting when
     no watchdog is configured. */
  const unsigned long long wd_usec = sd_notify::watchdog_usec();
  const uint64_t wd_interval_ms = wd_usec > 0 ? (wd_usec / 1000ULL) / 2ULL : 0;
  uint64_t wd_last_ms = 0;
  if (wd_interval_ms > 0) {
    get_ms(&wd_last_ms);
    spdlog::info("systemd watchdog enabled: petting every {} ms (WatchdogSec={} s)",
                 wd_interval_ms, wd_usec / 1000000ULL);
  }

  while (1) {
    if (wd_interval_ms > 0) {
      uint64_t now_ms = 0;
      if (get_ms(&now_ms) == 0 && (now_ms - wd_last_ms) >= wd_interval_ms) {
        sd_notify::watchdog();
        wd_last_ms = now_ms;
      }
    }

    if (do_update_conns) {
      update_conns(source_ip_file);
      do_update_conns = 0;
    }

    connection_housekeeping();

    fd_set read_fds = active_fds;
    struct timeval to = {.tv_sec = 0, .tv_usec = 200 * 1000};
    ret = select(FD_SETSIZE, &read_fds, NULL, NULL, &to);

    if (ret > 0) {
      if (FD_ISSET(listenfd, &read_fds)) {
        handle_srt_data(listenfd);
      }

      for (conn_t *c = conns; c != NULL; c = c->next) {
        if (c->fd >= 0 && FD_ISSET(c->fd, &read_fds)) {
          handle_srtla_data(c);
        }
      }
    } // ret > 0

    info_int--;
    if (info_int == 0) {
      for (conn_t *c = conns; c != NULL; c = c->next) {
        spdlog::debug("{} ({}): in flight: {}, window: {}, last_rcvd {}",
                      print_addr(&c->src), fmt::ptr(c), c->in_flight_pkts,
                      c->window, c->last_rcvd);
      }
      info_int = LOG_PKT_INT;
    }
  } // while(1);
}
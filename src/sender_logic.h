/*
    srtla - SRT transport proxy with link aggregation, forked by IRLServer
    Copyright (C) 2020-2021 BELABOX project
    Copyright (C) 2025 IRLServer.com
    Copyright (C) 2026 CeraLive

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

/*
    Pure sender-side decision logic, extracted from sender.cpp so it can be
    unit-tested without sockets, signals, or the file-scope connection list.

    Everything here is a free function over plain scalars / a file path; it
    holds no state and touches no globals. sender.cpp routes its real
    connection_housekeeping() / conn_timed_out() / update_conns() decisions
    through these helpers so the tests pin the *shipped* behavior, not a
    parallel re-implementation.
*/

#pragma once

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>

#include <netinet/in.h>

extern "C" {
#include "common.h"
}

namespace srtla::sender {

// Sender connection timing constants — single source of truth shared between
// sender.cpp and the unit tests.
//
// Rationale: fixes SenderFalselyDownsAliveLinkOnSubReceiverTimeoutGap (Task 9
// case d). The passive inbound-silence timeout is aligned with the receiver's
// CONN_TIMEOUT (receiver_config.h, 15 s). Below that window the receiver still
// holds the link and keeps echoing keepalives, so the two ends must agree on
// liveness: a sender that gives up 3.75x sooner (the old 4 s) needlessly
// re-registers and resets the window to WINDOW_MIN on a link that is merely
// mid radio-stall (the "server in another country" false link-down) while the
// receiver and the physical link are fine.
//
// Detection latency for a genuinely dead link is NOT sacrificed: it is caught
// by a timeout-independent path — a hard send failure (sendto() error on an
// isolated / torn-down link) immediately disables the connection in
// handle_srt_data() (sender.cpp), and a struggling link is deselected by
// select_conn() scoring within ~1 s. This widening only suppresses the sub-15 s
// false positives; it does not slow real link-drop shifts (link-drop.sh /
// link-drop-high-rtt.sh detect via the sendto-failure path in <1 s).
inline constexpr time_t SENDER_CONN_TIMEOUT = 15; // s of inbound silence => failed (matches receiver CONN_TIMEOUT)
inline constexpr time_t SENDER_IDLE_TIME = 1;     // s before an idle link is pinged

// A connection that has never received anything (last_rcvd == 0) is *not yet
// established*, not timed out.
//
// Regression guard for commit 906ac05: the pre-fix predicate was
// `(last_rcvd + CONN_TIMEOUT) < now`, which for last_rcvd == 0 is
// `CONN_TIMEOUT < now` — always true once the monotonic clock passes
// CONN_TIMEOUT seconds. That made every fresh link look "timed out", so
// select_conn() skipped it and group registration never bootstrapped.
inline bool conn_is_timed_out(time_t last_rcvd, time_t now) {
  if (last_rcvd == 0) {
    return false;
  }
  return (last_rcvd + SENDER_CONN_TIMEOUT) < now;
}

// The three mutually-exclusive states connection_housekeeping() drives a link
// through on each tick. Extracting this as a pure predicate makes the 906ac05
// bootstrap path (BootstrapRegister) unit-testable without sockets or globals.
enum class HousekeepingAction {
  TimedOutReconnect, // last_rcvd > 0 but stale: reset window + re-register
  BootstrapRegister, // last_rcvd == 0: never registered, drive first REG2/REG1
  ActiveKeepalive,   // recently received: healthy, keepalive when idle
};

inline HousekeepingAction housekeeping_action(time_t last_rcvd, time_t now) {
  if (conn_is_timed_out(last_rcvd, now)) {
    return HousekeepingAction::TimedOutReconnect;
  }
  if (last_rcvd == 0) {
    return HousekeepingAction::BootstrapRegister;
  }
  return HousekeepingAction::ActiveKeepalive;
}

// Whether an active link is overdue for a NAT keepalive (idle longer than
// SENDER_IDLE_TIME). Only meaningful for ActiveKeepalive links.
inline bool keepalive_due(time_t last_sent, time_t now) {
  return (last_sent + SENDER_IDLE_TIME) < now;
}

// Detailed reload error information for logging.
enum class ReloadError {
  None,           // No error, reload should apply
  FileNotFound,   // File cannot be opened
  FileEmpty,      // File exists but contains no valid IPs
  InvalidLine,    // File contains invalid IP lines (but may have valid ones)
  ZeroValidIPs,   // File exists but all lines are invalid
};

// Count how many parseable IPv4 source addresses a source-ip file contains,
// without mutating any global connection state. Returns 0 for a file that
// cannot be opened, is empty, or contains only unparseable lines.
//
// update_conns() consults this before applying a SIGHUP reload: a reload that
// would yield zero valid source IPs (empty / garbage / unreadable file) is
// refused so the stream keeps running on the existing links instead of having
// every connection torn down. See sighup-reload negative scenario.
inline int count_parseable_source_ips(const char *path) {
  FILE *f = fopen(path, "r");
  if (f == nullptr) {
    return 0;
  }

  int count = 0;
  char *line = nullptr;
  size_t line_len = 0;
  while (getline(&line, &line_len, f) >= 0) {
    char *nl = strchr(line, '\n');
    if (nl != nullptr) {
      *nl = '\0';
    }
    struct sockaddr_in src;
    if (parse_ip(&src, line) == 0) {
      count++;
    }
  }

  free(line);
  fclose(f);
  return count;
}

// Detailed reload error analysis: returns specific error type and optionally
// populates error_line_num with the line number of the first invalid line
// (1-indexed). Used for precise error logging in update_conns().
inline ReloadError analyze_reload_error(const char *path, int *error_line_num = nullptr) {
  FILE *f = fopen(path, "r");
  if (f == nullptr) {
    return ReloadError::FileNotFound;
  }

  int count = 0;
  int line_num = 0;
  char *line = nullptr;
  size_t line_len = 0;
  bool has_invalid_line = false;
  int first_invalid_line = 0;

  while (getline(&line, &line_len, f) >= 0) {
    line_num++;
    char *nl = strchr(line, '\n');
    if (nl != nullptr) {
      *nl = '\0';
    }
    // Skip empty lines
    if (line[0] == '\0') {
      continue;
    }
    struct sockaddr_in src;
    if (parse_ip(&src, line) == 0) {
      count++;
    } else {
      has_invalid_line = true;
      if (first_invalid_line == 0) {
        first_invalid_line = line_num;
      }
    }
  }

  free(line);
  fclose(f);

  if (error_line_num != nullptr && first_invalid_line > 0) {
    *error_line_num = first_invalid_line;
  }

  if (count == 0 && line_num == 0) {
    return ReloadError::FileEmpty;
  }
  if (count == 0 && has_invalid_line) {
    return ReloadError::ZeroValidIPs;
  }
  if (has_invalid_line) {
    return ReloadError::InvalidLine;
  }
  return ReloadError::None;
}

// Predicate form of the reload guard, for callers that already have a count.
inline bool reload_should_apply(int parseable_ip_count) {
  return parseable_ip_count > 0;
}

} // namespace srtla::sender

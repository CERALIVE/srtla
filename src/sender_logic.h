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
inline constexpr time_t SENDER_CONN_TIMEOUT = 4; // s of inbound silence => failed
inline constexpr time_t SENDER_IDLE_TIME = 1;    // s before an idle link is pinged

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

// Predicate form of the reload guard, for callers that already have a count.
inline bool reload_should_apply(int parseable_ip_count) {
  return parseable_ip_count > 0;
}

} // namespace srtla::sender

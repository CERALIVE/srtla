/*
    srtla - SRT transport proxy with link aggregation

    Copyright (C) 2026 CERALIVE

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
*/

#ifndef SRTLA_SD_NOTIFY_H
#define SRTLA_SD_NOTIFY_H

#include <cerrno>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

/*
  Minimal, dependency-free sd_notify(3) for srtla_send (header-only so the
  CMake build needs no libsystemd link or extra translation unit).

  Talks directly to the AF_UNIX datagram socket named by $NOTIFY_SOCKET, set by
  systemd for units with Type=notify / WatchdogSec=. Every function is a safe
  no-op when not supervised by systemd (NOTIFY_SOCKET unset), so srtla_send
  behaves identically when launched directly.

  See ADR-0005: systemd is the sole restart authority; srtla_send pets
  WatchdogSec from its main loop so a hung/zombie bonding process is killed and
  respawned.
*/
namespace sd_notify {

inline int send_state(const char *state) {
  const char *path = getenv("NOTIFY_SOCKET");
  if (path == nullptr || (path[0] != '/' && path[0] != '@')) {
    return 0;
  }

  size_t path_len = strlen(path);
  struct sockaddr_un sa;
  if (path_len >= sizeof(sa.sun_path)) {
    return -E2BIG;
  }

  int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
  if (fd < 0) {
    return -errno;
  }

  memset(&sa, 0, sizeof(sa));
  sa.sun_family = AF_UNIX;
  memcpy(sa.sun_path, path, path_len + 1);

  socklen_t sa_len;
  if (sa.sun_path[0] == '@') {
    sa.sun_path[0] = '\0';
    sa_len = static_cast<socklen_t>(offsetof(struct sockaddr_un, sun_path) +
                                    path_len);
  } else {
    sa_len = static_cast<socklen_t>(offsetof(struct sockaddr_un, sun_path) +
                                    path_len + 1);
  }

  ssize_t n;
  do {
    n = sendto(fd, state, strlen(state), MSG_NOSIGNAL,
               reinterpret_cast<struct sockaddr *>(&sa), sa_len);
  } while (n < 0 && errno == EINTR);

  int ret = (n < 0) ? -errno : 1;
  close(fd);
  return ret;
}

inline int ready() { return send_state("READY=1\n"); }

inline int watchdog() { return send_state("WATCHDOG=1\n"); }

inline unsigned long long watchdog_usec() {
  const char *e = getenv("WATCHDOG_USEC");
  if (e == nullptr || *e == '\0') {
    return 0ULL;
  }
  int saved_errno = errno;
  errno = 0;
  char *end = nullptr;
  unsigned long long v = strtoull(e, &end, 10);
  if (errno != 0 || end == e) {
    errno = saved_errno;
    return 0ULL;
  }
  errno = saved_errno;
  return v;
}

} // namespace sd_notify

#endif // SRTLA_SD_NOTIFY_H

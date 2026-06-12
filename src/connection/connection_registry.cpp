#include "connection_registry.h"

#include <algorithm>

#include <spdlog/spdlog.h>

#include "../receiver_config.h"
#include "../utils/network_utils.h"


extern "C" {
#include "../common.h"
}
namespace srtla::connection {

using srtla::utils::NetworkUtils;

namespace {

bool addresses_equal(const struct sockaddr_storage &a, const struct sockaddr_storage &b) {
    if (a.ss_family != b.ss_family) {
        return false;
    }

    if (a.ss_family == AF_INET6) {
        auto *addr_a = reinterpret_cast<const struct sockaddr_in6 *>(&a);
        auto *addr_b = reinterpret_cast<const struct sockaddr_in6 *>(&b);
        return NetworkUtils::constant_time_compare(&addr_a->sin6_addr, &addr_b->sin6_addr, sizeof(struct in6_addr)) == 0 &&
               addr_a->sin6_port == addr_b->sin6_port;
    }

    auto *addr_a = reinterpret_cast<const struct sockaddr_in *>(&a);
    auto *addr_b = reinterpret_cast<const struct sockaddr_in *>(&b);
    return NetworkUtils::constant_time_compare(&addr_a->sin_addr, &addr_b->sin_addr, sizeof(struct in_addr)) == 0 &&
           addr_a->sin_port == addr_b->sin_port;
}

bool conn_timed_out(const ConnectionPtr &conn, time_t ts) {
    return (conn->last_received() + CONN_TIMEOUT) < ts;
}

} // namespace

ConnectionRegistry &ConnectionRegistry::instance() {
    static ConnectionRegistry registry;
    return registry;
}

void ConnectionRegistry::add_group(const ConnectionGroupPtr &group) {
    groups_.push_back(group);
    if (on_group_registered) {
        on_group_registered(group->identity());
    }
}

void ConnectionRegistry::remove_group(const ConnectionGroupPtr &group) {
    // Find-then-erase (not erase-remove) so the reaped hook fires exactly once:
    // a repeat teardown of an already-removed group is a no-op with no hook.
    auto it = std::find(groups_.begin(), groups_.end(), group);
    if (it == groups_.end()) {
        return;
    }
    if (on_group_reaped) {
        on_group_reaped(group->identity());
    }
    groups_.erase(it);
}

bool ConnectionRegistry::evict_oldest_pending_group() {
    ConnectionGroupPtr oldest;
    for (auto &group : groups_) {
        if (!group->connections().empty() || group->has_seen_data()) {
            continue;
        }
        if (!oldest || group->created_at() < oldest->created_at()) {
            oldest = group;
        }
    }

    if (!oldest) {
        return false;
    }

    spdlog::warn("[Group: {}] Evicting pending group to admit new registration (group table full)",
                 static_cast<void *>(oldest.get()));
    remove_group(oldest);
    return true;
}

ConnectionGroupPtr ConnectionRegistry::find_group_by_id(const char *id) {
    for (auto &group : groups_) {
        if (NetworkUtils::constant_time_compare(group->id().data(), id, SRTLA_ID_LEN) == 0) {
            return group;
        }
    }
    return nullptr;
}

void ConnectionRegistry::find_by_address(const struct sockaddr_storage *addr,
                                         ConnectionGroupPtr &out_group,
                                         ConnectionPtr &out_conn) {
    for (auto &group : groups_) {
        for (auto &conn : group->connections()) {
            if (addresses_equal(conn->address(), *addr)) {
                out_group = group;
                out_conn = conn;
                return;
            }
        }

        if (addresses_equal(group->last_address(), *addr)) {
            out_group = group;
            out_conn.reset();
            return;
        }
    }

    out_group.reset();
    out_conn.reset();
}

void ConnectionRegistry::cleanup_inactive(time_t current_time,
                                          const std::function<void(ConnectionPtr, time_t)> &keepalive_cb) {
    // Rationale: fixes ReceiverRecoveryWindowStarvedByCleanupThrottle (Task 9).
    // Recovery/NAT keepalives must probe at KEEPALIVE_PERIOD(1s) cadence, but the
    // reaping body below self-throttles to CLEANUP_PERIOD(3s); firing keepalives
    // only from that body delivered ~2 of the intended ~5 probes across a 5s
    // RECOVERY_CHANCE_PERIOD window. Run the keepalive pass on every call,
    // decoupled from the reaping throttle. A per-connection last-sent stamp keeps
    // the true cadence at one per KEEPALIVE_PERIOD even when the main loop polls
    // cleanup_inactive many times in the same second under load.
    if (keepalive_cb) {
        for (auto &group : groups_) {
            for (auto &conn : group->connections()) {
                if (conn_timed_out(conn, current_time)) {
                    continue;
                }
                if ((conn->last_received() + KEEPALIVE_PERIOD) < current_time &&
                    (conn->last_keepalive_sent() + KEEPALIVE_PERIOD) <= current_time) {
                    keepalive_cb(conn, current_time);
                    conn->set_last_keepalive_sent(current_time);
                }
            }
        }
    }

    static time_t last_run = 0;
    if ((last_run + CLEANUP_PERIOD) > current_time) {
        return;
    }
    last_run = current_time;

    if (groups_.empty()) {
        return;
    }

    spdlog::debug("Starting a cleanup run...");

    std::size_t total_groups = groups_.size();
    std::size_t total_connections = 0;
    std::size_t removed_groups = 0;
    std::size_t removed_connections = 0;

    for (auto group_it = groups_.begin(); group_it != groups_.end();) {
        auto group = *group_it;
        std::size_t before_conns = group->connections().size();
        total_connections += before_conns;

        auto &connections = group->connections();
        for (auto conn_it = connections.begin(); conn_it != connections.end();) {
            auto conn = *conn_it;

            // Snapshot before the recovery branch clears recovery_start, so a
            // reaped link reads recovery_fail vs a plain idle timeout.
            const bool was_recovering = conn->recovery_start() > 0;

            if (conn->recovery_start() > 0) {
                if (conn->last_received() > conn->recovery_start()) {
                    if ((current_time - conn->recovery_start()) > RECOVERY_CHANCE_PERIOD) {
                        spdlog::info("[{}:{}] [Group: {}] Connection recovery completed",
                                     print_addr(const_cast<struct sockaddr *>(reinterpret_cast<const struct sockaddr *>(&conn->address()))),
                                     port_no(const_cast<struct sockaddr *>(reinterpret_cast<const struct sockaddr *>(&conn->address()))),
                                     static_cast<void *>(group.get()));
                        conn->set_recovery_start(0);
                    }
                } else if ((conn->recovery_start() + RECOVERY_CHANCE_PERIOD) < current_time) {
                    spdlog::info("[{}:{}] [Group: {}] Connection recovery failed",
                                 print_addr(const_cast<struct sockaddr *>(reinterpret_cast<const struct sockaddr *>(&conn->address()))),
                                 port_no(const_cast<struct sockaddr *>(reinterpret_cast<const struct sockaddr *>(&conn->address()))),
                                 static_cast<void *>(group.get()));
                    conn->set_recovery_start(0);
                }
            }

            if (conn_timed_out(conn, current_time)) {
                const char *reason = was_recovering ? "recovery_fail" : "timeout";
                conn_it = connections.erase(conn_it);
                removed_connections++;
                spdlog::info("[{}:{}] [Group: {}] conn_removed group={} reason={} conns={}",
                             print_addr(const_cast<struct sockaddr *>(reinterpret_cast<const struct sockaddr *>(&conn->address()))),
                             port_no(const_cast<struct sockaddr *>(reinterpret_cast<const struct sockaddr *>(&conn->address()))),
                             static_cast<void *>(group.get()),
                             group->short_id(),
                             reason,
                             connections.size());
            } else {
                // Keepalives are sent from the decoupled pass at the top of
                // cleanup_inactive (Task 9 fix), not here, so they keep their
                // KEEPALIVE_PERIOD cadence instead of the CLEANUP_PERIOD throttle.
                ++conn_it;
            }
        }

        time_t empty_timeout = group->has_seen_data() ? GROUP_TIMEOUT : PENDING_GROUP_TIMEOUT;
        if (connections.empty() && (group->created_at() + empty_timeout) < current_time) {
            if (on_group_reaped) {
                on_group_reaped(group->identity());
            }
            group_it = groups_.erase(group_it);
            removed_groups++;
            spdlog::info("[Group: {}] group_reaped group={} reason=idle_timeout",
                         static_cast<void *>(group.get()), group->short_id());
        } else {
            if (before_conns != connections.size()) {
                group->write_socket_info_file();
            }
            ++group_it;
        }
    }

    spdlog::debug("Clean up run ended. Counted {} groups and {} connections. Removed {} groups and {} connections",
                  total_groups, total_connections, removed_groups, removed_connections);
}

} // namespace srtla::connection

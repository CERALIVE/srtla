#pragma once

#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "connection_group.h"

namespace srtla::connection {

class ConnectionRegistry {
public:
    ConnectionRegistry() = default;

    static ConnectionRegistry &instance();

    void add_group(const ConnectionGroupPtr &group);
    void remove_group(const ConnectionGroupPtr &group);

    ConnectionGroupPtr find_group_by_id(const char *id);
    void find_by_address(const struct sockaddr_storage *addr,
                         ConnectionGroupPtr &out_group,
                         ConnectionPtr &out_conn);

    std::vector<ConnectionGroupPtr> &groups() { return groups_; }
    const std::vector<ConnectionGroupPtr> &groups() const { return groups_; }

    void cleanup_inactive(time_t current_time,
                          const std::function<void(ConnectionPtr, time_t)> &keepalive_cb);

    // Service-primitive lifecycle hooks (multi-tenant groundwork). Unset by
    // default: when empty the registry behaves exactly as before — no call, no
    // log, no allocation. A future service layer installs these to observe
    // group identity at register/teardown without touching the data path.
    std::function<void(const GroupIdentity &)> on_group_registered;
    std::function<void(const GroupIdentity &)> on_group_reaped;

    // Stream-id awareness extension point. MAY return routing metadata for a
    // future multi-target receiver; the current single-target receiver never
    // consults it, so the single shared SRT target is preserved unchanged.
    std::function<std::optional<std::string>(const GroupIdentity &)> stream_id_resolver;

private:
    std::vector<ConnectionGroupPtr> groups_;
};

} // namespace srtla::connection

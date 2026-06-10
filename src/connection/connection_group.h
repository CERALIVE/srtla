#pragma once

#include <array>
#include <chrono>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

#include "connection.h"
#include "../receiver_config.h"
#include "../utils/nak_dedup.h"

extern "C" {
#include "../common.h"
}

namespace srtla::connection {

using srtla::utils::NakHashEntry;

// Service-primitive identity snapshot for a connection group (multi-tenant
// groundwork). Carries only stable facts a future routing/tenancy layer keys
// on; it has no behavior and nothing consults external_id in this build.
struct GroupIdentity {
    std::string short_id;                                // first 4 id bytes as hex
    std::chrono::steady_clock::time_point registered_at; // group construction time
    std::vector<std::string> source_addresses;           // IP strings of current links
    std::string external_id;                             // opaque slot, empty by default
};

class ConnectionGroup {
public:
    ConnectionGroup(const char *client_id, time_t timestamp);
    ~ConnectionGroup();

    const std::array<char, SRTLA_ID_LEN> &id() const { return id_; }

    // Stable, low-cardinality handle for structured lifecycle logs: the first
    // four id bytes as hex. Greppable per group without leaking the full id.
    std::string short_id() const;

    // Identity snapshot for lifecycle hooks. source_addresses is rebuilt from
    // the live links, falling back to last_address before conn 0 joins / after
    // the last link is reaped, so the snapshot always carries >=1 source.
    GroupIdentity identity() const;

    const std::string &external_id() const { return identity_.external_id; }
    void set_external_id(std::string id) { identity_.external_id = std::move(id); }

    void add_connection(const ConnectionPtr &conn);
    void remove_connection(const ConnectionPtr &conn);

    std::vector<ConnectionPtr> &connections() { return conns_; }
    const std::vector<ConnectionPtr> &connections() const { return conns_; }

    time_t created_at() const { return created_at_; }

    int srt_socket() const { return srt_sock_; }
    void set_srt_socket(int sock);

    const struct sockaddr_storage &last_address() const { return last_addr_; }
    void set_last_address(const struct sockaddr_storage &addr) { last_addr_ = addr; }

    uint64_t total_target_bandwidth() const { return total_target_bandwidth_; }
    void set_total_target_bandwidth(uint64_t bw) { total_target_bandwidth_ = bw; }

    time_t last_quality_eval() const { return last_quality_eval_; }
    void set_last_quality_eval(time_t ts) { last_quality_eval_ = ts; }

    time_t last_load_balance_eval() const { return last_load_balance_eval_; }
    void set_last_load_balance_eval(time_t ts) { last_load_balance_eval_ = ts; }
 
    bool load_balancing_enabled() const { return load_balancing_enabled_; }
    void set_load_balancing_enabled(bool enabled) { load_balancing_enabled_ = enabled; }


    std::unordered_map<uint64_t, NakHashEntry> &nak_cache() { return nak_seen_hash_; }

    std::vector<struct sockaddr_storage> get_client_addresses() const;
    void write_socket_info_file() const;
    void remove_socket_info_file() const;

    void set_epoll_fd(int fd) { epoll_fd_ = fd; }

private:
    std::vector<std::string> source_address_strings() const;

    std::array<char, SRTLA_ID_LEN> id_ {};
    std::vector<ConnectionPtr> conns_;
    GroupIdentity identity_;
    time_t created_at_ = 0;
    int srt_sock_ = -1;
    struct sockaddr_storage last_addr_ {};

    uint64_t total_target_bandwidth_ = 0;
    time_t last_quality_eval_ = 0;
    time_t last_load_balance_eval_ = 0;
    bool load_balancing_enabled_ = true;


    std::unordered_map<uint64_t, NakHashEntry> nak_seen_hash_;
    int epoll_fd_ = -1;
};

using ConnectionGroupPtr = std::shared_ptr<ConnectionGroup>;

} // namespace srtla::connection

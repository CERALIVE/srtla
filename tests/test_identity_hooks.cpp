/*
    srtla - SRT transport proxy with link aggregation
    Copyright (C) 2026 CeraLive

    Service-primitive identity hooks (Task 16) — multi-tenant groundwork.

    Pins the GroupIdentity snapshot and the registration/teardown extension
    points added to ConnectionRegistry, WITHOUT introducing any behavior change
    for the single-tenant build:

      * on_group_registered fires once at group registration, carrying a
        GroupIdentity with a non-empty short_id, a registration timestamp, and
        >=1 source address (the registering link, before conn 0 joins);
      * on_group_reaped fires exactly once per teardown — both the idle-timeout
        reaper path and the explicit remove_group path, and never twice for a
        group already gone;
      * the default (no-hook) path is byte-identical: the std::function members
        are empty on a fresh registry and installing a hook is purely additive
        to the observable group trajectory;
      * stream_id_resolver is a declared extension point only — its return is
        never consulted by the current single-target receiver, so a full
        register -> teardown cycle never invokes it.

    The reaper keeps a process-static last_run, so the cleanup-driven test takes
    a fresh, strictly-increasing time base (fresh_base, atomic) to stay
    shuffle-safe, matching test_timeout_cleanup.
*/

#include <gtest/gtest.h>

#include <netinet/in.h>
#include <sys/socket.h>

#include <atomic>
#include <chrono>
#include <cstring>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "connection/connection.h"
#include "connection/connection_group.h"
#include "connection/connection_registry.h"
#include "receiver_config.h"
#include "handler_harness.h"

using srtla::CONN_TIMEOUT;
using srtla::GROUP_TIMEOUT;
using srtla::connection::Connection;
using srtla::connection::ConnectionGroup;
using srtla::connection::ConnectionGroupPtr;
using srtla::connection::ConnectionPtr;
using srtla::connection::ConnectionRegistry;
using srtla::connection::GroupIdentity;
using srtla::test::Client;
using srtla::test::HandlerHarness;
using srtla::test::make_client_id;

namespace {

time_t fresh_base() {
    static std::atomic<time_t> base{5'000'000};
    return base.fetch_add(1'000'000);
}

struct sockaddr_storage make_addr(uint16_t port) {
    struct sockaddr_storage ss;
    std::memset(&ss, 0, sizeof(ss));
    auto *in = reinterpret_cast<struct sockaddr_in *>(&ss);
    in->sin_family = AF_INET;
    in->sin_port = htons(port);
    in->sin_addr.s_addr = htonl(0x7f000001);
    return ss;
}

ConnectionGroupPtr make_group(time_t created_at) {
    char client_id[SRTLA_ID_LEN] = {'i', 'd', 'e', 'n', 't', 0};
    auto group = std::make_shared<ConnectionGroup>(client_id, created_at);
    group->set_last_address(make_addr(40000));
    return group;
}

} // namespace

// -- GroupIdentity snapshot --------------------------------------------------

TEST(IdentityHooks, ShortIdMatchesGroupShortId) {
    auto group = make_group(1000);
    EXPECT_EQ(group->identity().short_id, group->short_id());
    EXPECT_FALSE(group->identity().short_id.empty());
}

TEST(IdentityHooks, ExternalIdEmptyByDefaultAndSettable) {
    auto group = make_group(1000);
    EXPECT_TRUE(group->identity().external_id.empty());
    EXPECT_TRUE(group->external_id().empty());

    group->set_external_id("tenant-acme-42");
    EXPECT_EQ(group->external_id(), "tenant-acme-42");
    EXPECT_EQ(group->identity().external_id, "tenant-acme-42");
}

TEST(IdentityHooks, SourceAddressesReflectConnections) {
    auto group = make_group(1000);
    auto conn = std::make_shared<Connection>(make_addr(50001), 1000);
    group->add_connection(conn);

    auto id = group->identity();
    ASSERT_EQ(id.source_addresses.size(), 1u);
    EXPECT_EQ(id.source_addresses[0], "127.0.0.1");
}

TEST(IdentityHooks, SourceAddressFallsBackToLastAddressWhenNoConnections) {
    auto group = make_group(1000); // last_address set, no connections yet
    auto id = group->identity();
    ASSERT_EQ(id.source_addresses.size(), 1u)
        << "registration/teardown windows have no links; last_address is the source";
    EXPECT_EQ(id.source_addresses[0], "127.0.0.1");
}

TEST(IdentityHooks, RegisteredAtIsSetAtConstruction) {
    auto before = std::chrono::steady_clock::now();
    auto group = make_group(1000);
    auto after = std::chrono::steady_clock::now();
    EXPECT_GE(group->identity().registered_at, before);
    EXPECT_LE(group->identity().registered_at, after);
}

// -- Registration hook (real handler path) -----------------------------------

TEST(IdentityHooks, RegistrationHookFiresWithIdentityOnRegister) {
    HandlerHarness h;
    std::vector<GroupIdentity> seen;
    h.registry().on_group_registered = [&](const GroupIdentity &id) { seen.push_back(id); };

    auto client = h.make_client();
    auto before = std::chrono::steady_clock::now();
    client.send_reg1(make_client_id(7));
    h.pump(2000);
    auto after = std::chrono::steady_clock::now();

    ASSERT_EQ(seen.size(), 1u) << "registration hook must fire exactly once";
    EXPECT_FALSE(seen[0].short_id.empty()) << "non-empty group short id";
    ASSERT_GE(seen[0].source_addresses.size(), 1u) << ">=1 source address at register";
    EXPECT_EQ(seen[0].source_addresses[0], "127.0.0.1");
    EXPECT_TRUE(seen[0].external_id.empty());
    EXPECT_GE(seen[0].registered_at, before);
    EXPECT_LE(seen[0].registered_at, after);
}

TEST(IdentityHooks, RegistrationHookShortIdMatchesRegisteredGroup) {
    HandlerHarness h;
    std::string hook_short_id;
    h.registry().on_group_registered = [&](const GroupIdentity &id) { hook_short_id = id.short_id; };

    auto client = h.make_client();
    client.send_reg1(make_client_id(11));
    h.pump(3000);

    ASSERT_EQ(h.registry().groups().size(), 1u);
    EXPECT_EQ(hook_short_id, h.registry().groups()[0]->short_id());
}

// -- Teardown hook: idle-timeout reaper --------------------------------------

TEST(IdentityHooks, ReapHookFiresExactlyOnceOnIdleTimeout) {
    time_t t0 = fresh_base();
    ConnectionRegistry reg;

    std::vector<GroupIdentity> reaped;
    reg.on_group_reaped = [&](const GroupIdentity &id) { reaped.push_back(id); };

    auto group = make_group(t0);
    auto conn = std::make_shared<Connection>(make_addr(50001), t0);
    group->add_connection(conn);
    reg.add_group(group);
    const std::string expected_short_id = group->short_id();

    reg.cleanup_inactive(t0 + GROUP_TIMEOUT + 1, nullptr); // conn times out, group reaped

    ASSERT_EQ(reg.groups().size(), 0u) << "group must be reaped";
    ASSERT_EQ(reaped.size(), 1u) << "reap hook fires exactly once";
    EXPECT_EQ(reaped[0].short_id, expected_short_id);
    ASSERT_GE(reaped[0].source_addresses.size(), 1u) << "last_address survives the reap";
    EXPECT_EQ(reaped[0].source_addresses[0], "127.0.0.1");
}

// -- Teardown hook: explicit remove_group ------------------------------------

TEST(IdentityHooks, RemoveGroupHookFiresExactlyOnceAndIsIdempotent) {
    ConnectionRegistry reg;
    int reaped = 0;
    std::string short_id;
    reg.on_group_reaped = [&](const GroupIdentity &id) {
        ++reaped;
        short_id = id.short_id;
    };

    auto group = make_group(1000);
    reg.add_group(group);
    ASSERT_EQ(reg.groups().size(), 1u);

    reg.remove_group(group);
    EXPECT_EQ(reg.groups().size(), 0u);
    EXPECT_EQ(reaped, 1) << "remove fires the hook once";
    EXPECT_EQ(short_id, group->short_id());

    reg.remove_group(group); // already gone
    EXPECT_EQ(reaped, 1) << "a repeat teardown of an absent group must not re-fire";
}

// -- Default (no-hook) path is byte-identical --------------------------------

TEST(IdentityHooks, HookMembersEmptyOnFreshRegistry) {
    ConnectionRegistry reg;
    EXPECT_FALSE(static_cast<bool>(reg.on_group_registered));
    EXPECT_FALSE(static_cast<bool>(reg.on_group_reaped));
    EXPECT_FALSE(static_cast<bool>(reg.stream_id_resolver));
}

TEST(IdentityHooks, HookInstallIsPurelyAdditiveToGroupTrajectory) {
    ConnectionRegistry control;
    ConnectionRegistry hooked;
    int events = 0;
    hooked.on_group_registered = [&](const GroupIdentity &) { ++events; };
    hooked.on_group_reaped = [&](const GroupIdentity &) { ++events; };

    auto cg = make_group(1000);
    auto hg = make_group(1000);

    control.add_group(cg);
    hooked.add_group(hg);
    EXPECT_EQ(control.groups().size(), hooked.groups().size());

    control.remove_group(cg);
    hooked.remove_group(hg);
    EXPECT_EQ(control.groups().size(), hooked.groups().size());

    EXPECT_EQ(events, 2) << "hooks observed register+reap; control saw the same group trajectory";
}

// -- Stream-id resolver is declared but never consulted ----------------------

TEST(IdentityHooks, StreamIdResolverIsNeverConsultedAcrossLifecycle) {
    time_t t0 = fresh_base();
    ConnectionRegistry reg;

    int resolver_calls = 0;
    reg.stream_id_resolver = [&](const GroupIdentity &) -> std::optional<std::string> {
        ++resolver_calls;
        return std::string("route-to-tenant"); // a value the receiver must ignore
    };

    auto group = make_group(t0);
    auto conn = std::make_shared<Connection>(make_addr(50001), t0);
    group->add_connection(conn);
    reg.add_group(group);
    reg.remove_group(group);

    auto group2 = make_group(t0);
    group2->add_connection(std::make_shared<Connection>(make_addr(50002), t0));
    reg.add_group(group2);
    reg.cleanup_inactive(t0 + GROUP_TIMEOUT + 1, nullptr);

    EXPECT_EQ(resolver_calls, 0)
        << "single-target receiver must never consult the stream-id resolver";
}

TEST(IdentityHooks, StreamIdResolverNotConsultedOnHandlerRegisterPath) {
    HandlerHarness h;
    int resolver_calls = 0;
    h.registry().stream_id_resolver = [&](const GroupIdentity &) -> std::optional<std::string> {
        ++resolver_calls;
        return std::nullopt;
    };

    auto client = h.make_client();
    client.send_reg1(make_client_id(21));
    h.pump(3000);

    ASSERT_EQ(h.registry().groups().size(), 1u);
    EXPECT_EQ(resolver_calls, 0) << "registration must not route through the resolver";
}

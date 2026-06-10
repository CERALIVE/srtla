/*
    srtla - SRT transport proxy with link aggregation
    Copyright (C) 2026 CeraLive

    Tests for src/sender_logic.h — the pure sender-side decision logic that
    sender.cpp routes its connection_housekeeping() / conn_timed_out() /
    update_conns() decisions through.

    The headline regression guard is commit 906ac05 ("bootstrap initial SRTLA
    registration for never-connected links"): a link that has never received
    anything (last_rcvd == 0) must NOT be classified as timed out, and the
    housekeeping tick that follows must drive it down the BootstrapRegister
    (REG2/REG1) path rather than the keepalive path. Reverting either half of
    906ac05 flips one of these assertions:

      * revert the conn_timed_out fix  -> fresh link reads as TimedOutReconnect
      * revert the bootstrap branch    -> fresh link reads as ActiveKeepalive

    The second group pins the SIGHUP reload guard in update_conns(): a reload
    that resolves to zero valid source IPs (empty / garbage / unreadable file)
    must be refused so the stream keeps running on the existing links.
*/

#include <gtest/gtest.h>

#include <cstdio>
#include <string>

#include "sender_logic.h"

namespace {

using namespace srtla::sender;

// A monotonic "now" comfortably past CONN_TIMEOUT, mirroring the runtime where
// get_ms()/1000 has been climbing since boot — the exact condition under which
// the pre-906ac05 `(0 + CONN_TIMEOUT) < now` bug always fired.
constexpr time_t kNow = 1000;

TEST(SenderConnTimeout, NeverReceivedIsNotTimedOut) {
    EXPECT_FALSE(conn_is_timed_out(0, kNow));
    EXPECT_FALSE(conn_is_timed_out(0, SENDER_CONN_TIMEOUT));
    EXPECT_FALSE(conn_is_timed_out(0, SENDER_CONN_TIMEOUT + 1));
}

TEST(SenderConnTimeout, RecentlyReceivedIsActive) {
    EXPECT_FALSE(conn_is_timed_out(kNow, kNow));
    EXPECT_FALSE(conn_is_timed_out(kNow - SENDER_CONN_TIMEOUT, kNow));
}

TEST(SenderConnTimeout, StaleConnectionIsTimedOut) {
    EXPECT_TRUE(conn_is_timed_out(kNow - SENDER_CONN_TIMEOUT - 1, kNow));
}

// --- 906ac05 bootstrap path -------------------------------------------------

TEST(SenderHousekeeping, FreshLinkBootstrapsOnFirstTick) {
    EXPECT_EQ(housekeeping_action(0, kNow), HousekeepingAction::BootstrapRegister);
    EXPECT_EQ(housekeeping_action(0, SENDER_CONN_TIMEOUT + 1),
              HousekeepingAction::BootstrapRegister);
}

TEST(SenderHousekeeping, StaleLinkReconnects) {
    EXPECT_EQ(housekeeping_action(kNow - SENDER_CONN_TIMEOUT - 1, kNow),
              HousekeepingAction::TimedOutReconnect);
}

TEST(SenderHousekeeping, ActiveLinkKeepalive) {
    EXPECT_EQ(housekeeping_action(kNow, kNow), HousekeepingAction::ActiveKeepalive);
    EXPECT_EQ(housekeeping_action(kNow - SENDER_CONN_TIMEOUT, kNow),
              HousekeepingAction::ActiveKeepalive);
}

TEST(SenderKeepalive, DueOnlyAfterIdleTime) {
    EXPECT_FALSE(keepalive_due(kNow, kNow));
    EXPECT_FALSE(keepalive_due(kNow - SENDER_IDLE_TIME, kNow));
    EXPECT_TRUE(keepalive_due(kNow - SENDER_IDLE_TIME - 1, kNow));
}

// --- SIGHUP reload guard ----------------------------------------------------

class TempIpsFile {
public:
    explicit TempIpsFile(const std::string &contents) {
        char tmpl[] = "/tmp/srtla_ips_test_XXXXXX";
        int fd = mkstemp(tmpl);
        path_ = tmpl;
        if (fd >= 0) {
            if (!contents.empty()) {
                [[maybe_unused]] ssize_t w =
                    write(fd, contents.data(), contents.size());
            }
            close(fd);
        }
    }
    ~TempIpsFile() {
        if (!path_.empty()) {
            ::remove(path_.c_str());
        }
    }
    const char *path() const { return path_.c_str(); }

private:
    std::string path_;
};

TEST(SenderReloadGuard, ValidIpsAreCounted) {
    TempIpsFile f("10.0.0.10\n10.0.1.10\n192.168.1.50\n");
    EXPECT_EQ(count_parseable_source_ips(f.path()), 3);
    EXPECT_TRUE(reload_should_apply(count_parseable_source_ips(f.path())));
}

TEST(SenderReloadGuard, GarbageFileYieldsZeroAndIsRefused) {
    TempIpsFile f("not-an-ip\nlol\n???\n");
    EXPECT_EQ(count_parseable_source_ips(f.path()), 0);
    EXPECT_FALSE(reload_should_apply(count_parseable_source_ips(f.path())));
}

TEST(SenderReloadGuard, EmptyFileYieldsZeroAndIsRefused) {
    TempIpsFile f("");
    EXPECT_EQ(count_parseable_source_ips(f.path()), 0);
    EXPECT_FALSE(reload_should_apply(count_parseable_source_ips(f.path())));
}

TEST(SenderReloadGuard, MixedFileCountsOnlyValidLines) {
    TempIpsFile f("10.0.0.10\ngarbage\n\n10.0.1.10\n");
    EXPECT_EQ(count_parseable_source_ips(f.path()), 2);
}

TEST(SenderReloadGuard, UnreadableFileYieldsZeroAndIsRefused) {
    EXPECT_EQ(count_parseable_source_ips("/tmp/srtla_does_not_exist_xyz"), 0);
    EXPECT_FALSE(
        reload_should_apply(count_parseable_source_ips("/tmp/srtla_does_not_exist_xyz")));
}

} // namespace

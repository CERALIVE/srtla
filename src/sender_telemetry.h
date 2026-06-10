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
    Sender telemetry IPC — Option A from ADR-001 (docs/adr/ADR-001-telemetry-ipc.md).

    srtla_send publishes a per-uplink JSON snapshot to a stats file by writing a
    temp sibling and rename(2)-ing it over the live path, so a reader (the
    Bun-only CeraUI backend) always sees a complete previous-or-next snapshot,
    never a torn write.

    Everything here is pure: free functions over plain scalars / a file path,
    no globals, no sockets, no process state. sender.cpp gathers a
    TelemetrySnapshot per active link from its conn_t list and routes the write
    through these helpers; the unit tests pin the *shipped* serializer and the
    atomic-publish guarantee against golden fixtures without a live process.

    The field names and units mirror the on-the-wire connection_info_t
    (src/common.h:83-90) so the IPC schema and the keepalive struct never drift.
    The one mandated transform is bitrate: the wire field is bytes/s, the JSON
    field bitrate_bps is bits/s (multiply by 8) — see the ADR schema table.
*/

#pragma once

#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include <unistd.h>

namespace srtla::sender {

// Well-known path convention, mirroring the receiver's SRT_SOCKET_INFO_PREFIX
// ("/tmp/srtla-group-"). The live file is "<prefix><listen_port>.json"; CeraUI
// owns listen_port and computes the same path on the reader side (ADR-001).
inline constexpr const char *SENDER_TELEMETRY_PATH_PREFIX =
    "/tmp/srtla-send-stats-";

// A snapshot older than this (Date.now() - last_updated_ms) is dead. With the
// 1000 ms write cadence this tolerates ~5 missed writes before a wedged sender
// is caught — fixed by ADR-001 so the C producer and TS consumer agree.
inline constexpr uint64_t SENDER_TELEMETRY_STALE_MS = 5000;

// srtla_send does not run the receiver's load-balancer, so it has no per-link
// weight to differentiate; it reports every active link as optimal (= the
// receiver's WEIGHT_FULL level). Reporting a real weight would require porting
// the scoring algorithm into the sender, which is explicitly out of scope.
inline constexpr uint8_t SENDER_DEFAULT_WEIGHT_PERCENT = 100;

// One per-connection record. Field names/units mirror connection_info_t
// (src/common.h) plus weight_percent. bitrate is carried in bytes/s here and
// converted to bits/s (bitrate_bps) only at serialization, so the mandated x8
// conversion has a single, testable home.
struct TelemetrySnapshot {
  uint32_t conn_id = 0;
  uint32_t rtt_ms = 0;
  uint32_t nak_count = 0;
  uint8_t weight_percent = SENDER_DEFAULT_WEIGHT_PERCENT;
  int32_t window = 0;
  int32_t in_flight = 0;
  uint32_t bitrate_bytes_per_sec = 0; // JSON bitrate_bps = this * 8
};

// Default live path for a given listen port (the binding computes the same).
inline std::string telemetry_path(int listen_port) {
  return std::string(SENDER_TELEMETRY_PATH_PREFIX) +
         std::to_string(listen_port) + ".json";
}

// Serialize one snapshot to the exact ADR-001 JSON object. Pretty-printed with
// two-space indentation and a trailing newline so the on-disk file is the
// canonical example from the ADR. Zero links => "connections": [] with a fresh
// timestamp ("running but idle", distinct from "absent").
inline std::string
build_telemetry_json(uint64_t last_updated_ms,
                     const std::vector<TelemetrySnapshot> &conns) {
  std::string out;
  out.reserve(64 + conns.size() * 200);

  out += "{\n";
  out += "  \"last_updated_ms\": ";
  out += std::to_string(last_updated_ms);
  out += ",\n";

  if (conns.empty()) {
    out += "  \"connections\": []\n";
  } else {
    out += "  \"connections\": [\n";
    for (size_t i = 0; i < conns.size(); ++i) {
      const TelemetrySnapshot &c = conns[i];
      out += "    {\n";
      out += "      \"conn_id\": \"";
      out += std::to_string(c.conn_id);
      out += "\",\n";
      out += "      \"rtt_ms\": ";
      out += std::to_string(c.rtt_ms);
      out += ",\n";
      out += "      \"nak_count\": ";
      out += std::to_string(c.nak_count);
      out += ",\n";
      out += "      \"weight_percent\": ";
      out += std::to_string(static_cast<unsigned>(c.weight_percent));
      out += ",\n";
      out += "      \"window\": ";
      out += std::to_string(static_cast<int>(c.window));
      out += ",\n";
      out += "      \"in_flight\": ";
      out += std::to_string(static_cast<int>(c.in_flight));
      out += ",\n";
      out += "      \"bitrate_bps\": ";
      out += std::to_string(static_cast<uint64_t>(c.bitrate_bytes_per_sec) *
                            8ULL);
      out += "\n";
      out += (i + 1 < conns.size()) ? "    },\n" : "    }\n";
    }
    out += "  ]\n";
  }

  out += "}\n";
  return out;
}

// Publish a snapshot atomically: write "<path>.tmp", fsync, then rename(2) over
// the live path. rename on the same filesystem is atomic, so a concurrent
// reader never observes a partial document. Returns false (and cleans up the
// temp) on any I/O error; the previous good snapshot then stays on disk and
// goes stale rather than vanishing.
inline bool write_telemetry_atomic(const std::string &path,
                                   const std::string &json) {
  const std::string tmp = path + ".tmp";

  std::FILE *f = std::fopen(tmp.c_str(), "w");
  if (f == nullptr) {
    return false;
  }

  const size_t written = std::fwrite(json.data(), 1, json.size(), f);
  if (written != json.size()) {
    std::fclose(f);
    ::unlink(tmp.c_str());
    return false;
  }

  std::fflush(f);
  ::fsync(::fileno(f));
  std::fclose(f);

  if (::rename(tmp.c_str(), path.c_str()) != 0) {
    ::unlink(tmp.c_str());
    return false;
  }
  return true;
}

// Best-effort removal of the live file and any stale temp sibling, for clean
// shutdown. Async-signal-safe path variant lives in sender.cpp; this is the
// normal-context helper.
inline void remove_telemetry_file(const std::string &path) {
  ::unlink(path.c_str());
  const std::string tmp = path + ".tmp";
  ::unlink(tmp.c_str());
}

} // namespace srtla::sender

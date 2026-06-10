# @ceralive/srtla (TypeScript bindings)

Type-safe helpers for `srtla_send` and `srtla_rec`:

- Zod schemas for CLI options (sender/receiver) and IP list validation
- Defaults aligned with the srtla C++ implementation
- CLI arg builders (`buildSrtlaSendArgs`, `buildSrtlaRecArgs`)
- Process helpers (`getSrtlaExec`, `spawnSrtlaSend/Rec`, `sendHup`, `sendTerm`, `isRunning`)
- IP list utilities (`writeIpList`, `ipListSchema`)
- Sender telemetry reader (`readTelemetry`, `watchTelemetry`, `telemetrySchema`) — Bun-native, ADR-001

## Sender usage

```ts
import {
  buildSrtlaSendArgs,
  getSrtlaExec,
  spawnSrtlaSend,
  writeIpList,
} from "@ceralive/srtla/sender";

const { args, options } = buildSrtlaSendArgs({
  listenPort: 9000,
  srtlaHost: "relay.example.com",
  srtlaPort: 8890,
  ipsFile: "/tmp/srtla_ips",
  verbose: true,
});

writeIpList(["10.0.0.10", "10.0.1.10"], options.ipsFile);
const child = spawnSrtlaSend({ args, execPath: "/usr/bin" });
```

## Receiver usage

```ts
import {
  buildSrtlaRecArgs,
  getSrtlaExec,
  spawnSrtlaRec,
} from "@ceralive/srtla/receiver";

const { args } = buildSrtlaRecArgs({
  srtlaPort: 5000,
  srtHostname: "127.0.0.1",
  srtPort: 5001,
});

const child = spawnSrtlaRec({ args, execPath: "/usr/bin" });
```

## Telemetry (sender stats file, ADR-001)

Opt-in, read-only per-uplink telemetry. Start `srtla_send` with `statsFile`
(`--stats-file`) so it publishes a JSON snapshot, then read it Bun-natively
(`Bun.file`, no Node `fs`/process plumbing). Absent, unparseable, or stale
(> 5000 ms) snapshots return `null` — stock/upstream senders simply yield `null`.

```ts
import {
  readTelemetry,
  watchTelemetry,
  senderTelemetryPath,
} from "@ceralive/srtla/telemetry";

const path = senderTelemetryPath(5000); // /tmp/srtla-send-stats-5000.json

const snapshot = await readTelemetry(path); // Telemetry | null
if (snapshot) {
  for (const c of snapshot.connections) {
    console.log(c.conn_id, c.rtt_ms, c.weight_percent, c.bitrate_bps);
  }
}

// Or poll on a cadence (default 1000ms); cb receives null on absent/stale.
const handle = watchTelemetry(path, (t) => render(t), { intervalMs: 1000 });
// handle.stop();
```

The schema, units, and 5000 ms staleness threshold mirror ADR-001 and the C++
producer (`src/sender_telemetry.h`) exactly. `bitrate_bps` is bits/s.

## Defaults

- Sender listen port: `5000`
- Sender ips file: `/tmp/srtla_ips`
- Receiver srtla port: `5000`
- Receiver downstream SRT host: `127.0.0.1`
- Receiver downstream SRT port: `5001`

## License

AGPL-3.0 (matches the upstream srtla project)

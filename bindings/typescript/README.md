# @ceralive/srtla (TypeScript bindings)

Type-safe helpers for `srtla_send` and `srtla_rec`:

- Zod schemas for CLI options (sender/receiver) and IP list validation
- Defaults aligned with the srtla C++ implementation
- CLI arg builders (`buildSrtlaSendArgs`, `buildSrtlaRecArgs`)
- Process helpers (`getSrtlaExec`, `spawnSrtlaSend/Rec`, `sendHup`, `sendTerm`, `isRunning`)
- IP list utilities (`writeIpList`, `ipListSchema`)

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

## Defaults

- Sender listen port: `5000`
- Sender ips file: `/tmp/srtla_ips`
- Receiver srtla port: `5000`
- Receiver downstream SRT host: `127.0.0.1`
- Receiver downstream SRT port: `5001`

## License

AGPL-3.0 (matches the upstream srtla project)

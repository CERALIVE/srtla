# ADR-001: Sender Telemetry IPC Transport

## Status

Accepted

## Context

`srtla_send` (device side) already knows, per uplink, everything the operator
UI wants to display: round-trip time, NAK count, congestion window, in-flight
packets, per-link bitrate, and the load-balancer weight it is currently
assigning to each connection. Today none of that leaves the process — the only
sender-side IPC surfaces are the **IP-list file + `SIGHUP`** control path
(CeraUI writes `/tmp/srtla_ips`, then `kill -HUP`), and the wire-level extended
keepalive that carries `connection_info_t` to `srtla_rec`.

We need a **read-only telemetry channel out of `srtla_send`** so the CeraUI
backend can surface per-link quality in NetworkView. This ADR fixes the
transport and the on-the-wire JSON contract. It is a **GATE**: Tasks 18, 19, 21,
and 22 all implement against the schema decided here, so the field names, types,
units, and absence/staleness semantics must be nailed down before any code is
written.

### The consumer

The only consumer is the **CeraUI backend**, which is **Bun-only**:

- It reads via `Bun.file(path)` (file transport) or `Bun.connect(...)` (socket
  transport) — **never** by adding `node:child_process` plumbing. The existing
  srtla bindings already carry a `node:child_process` debt that must **not** be
  extended into new code.
- The backend's broadcast loop is **pull/poll based on a ~5 s cadence**
  (`netif` is 5 s; a link-telemetry broadcast would sit alongside it). It does
  **not** need sub-second push.
- The srtla TypeScript bindings API is **settled / frozen**. Whatever we add
  here must be **additive** — a new schema and a new reader export. Existing
  exports (`srtlaSendOptionsSchema`, `buildSrtlaSendArgs`, the spawn/`sendHup`
  helpers, etc.) do not change.

### Constraints (carried into the Decision)

- **Consumer is Bun** — `Bun.file` / `Bun.connect`, no new `node:child_process`.
- **Additive bindings only** — existing exports are frozen; add a new schema +
  reader.
- **Zero active links must be representable** — an empty connection list with a
  fresh timestamp, distinct from "absent".
- **Staleness must be defined in milliseconds** (this ADR sets it).
- **Absent transport must be non-fatal** — the binding returns `null`, never
  throws.
- **Our sender only** — telemetry exists exclusively for *our* `srtla_send`.
  Stock senders (BELABOX, Moblin, a hand-run upstream binary) produce **no**
  telemetry; the UI must render a calm empty state, not an error.
- **No new dependencies**, in either C/C++ or TypeScript.

### Field source of truth

The wire already defines the field semantics and units in
`src/common.h:83-90`:

```c
typedef struct __attribute__((__packed__)) {
  uint32_t conn_id;
  int32_t  window;
  int32_t  in_flight;
  uint32_t rtt_ms;
  uint32_t nak_count;
  uint32_t bitrate_bytes_per_sec;
} connection_info_t;
```

`weight_percent` is the sender load-balancer weight already tracked per
connection (`src/connection/connection.cpp`, seeded to `WEIGHT_FULL` = 100; the
levels are 100/85/70/55/40/10). The JSON contract **reuses these names and
units** so the on-the-wire struct and the IPC schema never drift.

> **Scope guard.** This ADR is about **sender-side** telemetry out of
> `srtla_send`. It does **not** touch or redesign the receiver-side
> `/tmp/srtla-group-<PORT>` socket-info files produced by `srtla_rec`. Those
> stay exactly as they are.

## Options Considered

### Option A: JSON Stats File (atomic rewrite)

Extend the existing file-based IPC philosophy. `srtla_send` periodically writes
a JSON snapshot to a well-known path keyed by its listen port — mirroring the
receiver's `SRT_SOCKET_INFO_PREFIX = "/tmp/srtla-group-"` naming — by writing to
a temp sibling and `rename(2)`-ing it over the live file. The binding reads it
with `Bun.file(path).json()`.

- **+** Consistent with every other srtla control surface (IP-list file,
  receiver group files). Operators and tests already understand "look in
  `/tmp`".
- **+** **Crash-safe by construction.** `rename(2)` on the same filesystem is
  atomic, so a reader always sees either the complete previous snapshot or the
  complete next one — never a torn write. If `srtla_send` dies, the **last good
  snapshot stays on disk** and goes stale (see staleness rule) rather than
  vanishing mid-read.
- **+** **Trivially testable.** Unit tests drop a fixture file and read it; no
  live process, no socket peer, no accept loop. C-side tests assert the file
  appears and updates. This is the cheapest possible test surface — important
  because Tasks 18/19/21/22 all need to test against it.
- **+** **Lifetime-decoupled / pull model.** Producer and consumer never need to
  be alive at the same instant; the consumer polls on its existing 5 s cadence.
  Late-attaching reader still gets current state.
- **+** Bun-native: `Bun.file(path).json()`. No new deps.
- **−** Polling latency: the UI is at best one write-interval + one poll-interval
  behind. Irrelevant for a 5 s UI cadence.
- **−** Leaves a file in `/tmp`. Bounded (one file per listen port), cleaned on
  reboot; producer truncates to an empty-connections snapshot when idle.

### Option B: Unix Domain Socket streaming NDJSON

`srtla_send` opens a `SOCK_STREAM` Unix socket, accepts a client, and pushes one
JSON object per line (newline-delimited JSON) whenever telemetry changes. CeraUI
attaches with `Bun.connect({ unix })` and parses lines.

- **+** Push / near-real-time; no polling latency.
- **+** No file litter in `/tmp` (just a socket inode).
- **−** **Reader-attach timing matters.** Anything emitted before CeraUI
  connects is lost; there is **no last-known-state** to read on (re)connect, so
  the empty/stale story is weaker.
- **−** **Producer must run an accept loop + manage client lifecycle**
  (backpressure, `EPIPE` on a slow/gone reader, partial-line framing across
  reads). That is materially more C code and more failure modes inside the hot
  sender process.
- **−** **Harder to test** — every test needs a live socket peer on both ends;
  no cheap fixture-file path.
- **−** Reconnect/buffering logic lands on the **Bun** side, growing the
  binding surface we are trying to keep additive and small.
- Push at sub-second rates is a capability we simply **do not need** at a 5 s UI
  cadence.

### Option C: Dedicated fd / stdout streaming NDJSON

`srtla_send` writes NDJSON telemetry lines to its own `stdout` (or an extra
inherited fd), and the binding parses the child's stream as it spawns it.

- **+** No file and no socket; rides the process it already spawns.
- **−** **Directly fights the Bun constraint.** Consuming a child's `stdout`
  stream as a structured data channel is exactly the `node:child_process`-style
  coupling we are forbidden from extending; CeraUI spawns `srtla_send` through
  its stream loop and would have to multiplex **human log lines vs. telemetry
  lines** on the same pipe.
- **−** `stdout` already carries human-readable logs (`--verbose`); interleaving
  a machine channel there is fragile line-framing waiting to break.
- **−** **No last-known-state.** Telemetry lives only as long as the pipe; a
  restart or a missed read loses everything, with nothing on disk to fall back
  to.
- **−** Couples telemetry lifetime rigidly to the spawn, and pushes stream
  parsing/reassembly into the binding.

## Decision

**Adopt Option A — a periodically-rewritten JSON stats file published via atomic
`rename(2)`.**

It is the only option that is simultaneously (1) consistent with the existing
srtla file-based IPC, (2) crash-safe without any in-process lifecycle
management, (3) cheaply testable with fixture files by every downstream task,
and (4) a clean fit for CeraUI's Bun-native, pull-based, ~5 s broadcast loop.
Options B and C buy sub-second push we do not need at the cost of reader-attach
fragility, no last-known-state, more failure modes in the sender hot path, and —
for C — a direct collision with the "no `node:child_process`" constraint.

### Producer (Task 18 — `srtla_send`, C/C++)

- Writes the snapshot to a temp sibling then `rename(2)`s it over the live path
  (atomic publish). No partial reads, ever.
- **Path:** `/tmp/srtla-send-stats-<listen_port>.json`, where `<listen_port>` is
  the local SRT listen port `srtla_send` was started with (CeraUI already owns
  this value — it sets `listenPort`). This mirrors the receiver's
  `/tmp/srtla-group-<PORT>` convention; define a
  `SENDER_TELEMETRY_PATH_PREFIX = "/tmp/srtla-send-stats-"` constant alongside
  `SRT_SOCKET_INFO_PREFIX`.
- **Write cadence:** every **1000 ms**, aligned to keepalive/housekeeping. (One
  write per second; the 5 s staleness threshold therefore tolerates ~5 missed
  writes before the snapshot is considered dead.)
- **Idle:** when there are zero active links it still writes, with
  `"connections": []` and a fresh `last_updated_ms`. "Running but idle" must be
  distinguishable from "absent".

### Consumer (Tasks 19/21/22 — CeraUI binding, additive)

- New **additive** export, e.g. `readSenderTelemetry(listenPort)`, that reads
  `Bun.file(SENDER_TELEMETRY_PATH_PREFIX + listenPort + ".json")`.
- New **additive** Zod schema mirroring the JSON below. Existing exports
  (`srtlaSendOptionsSchema`, builders, spawn helpers) are untouched.
- Returns `null` when the file is absent or unparseable; never throws (see
  Behaviors).
- Applies the staleness rule below before handing data to the broadcast layer.

## JSON Schema

A single JSON **object** per snapshot (not NDJSON — the file always holds
exactly one current object).

| Field | Type | Units / Range | Wire source | Notes |
|-------|------|---------------|-------------|-------|
| `last_updated_ms` | integer | Unix epoch **milliseconds** | producer clock (`get_ms`) | Wall-clock time this snapshot was written. Drives staleness. |
| `connections` | array of object | — | — | Per-connection records. **`[]` when no active links** (not omitted, not `null`). |
| `connections[].conn_id` | string | stable, unique per connection | wire `conn_id` (`uint32`), stringified | Stable identifier for one uplink slot for the life of the connection. String for forward flexibility. |
| `connections[].rtt_ms` | integer | **milliseconds**, ≥ 0 | wire `rtt_ms` (`uint32`) | Sender-measured round-trip time on this link. |
| `connections[].nak_count` | integer | **count**, cumulative, ≥ 0 | wire `nak_count` (`uint32`) | Cumulative NAKs observed on this link since connection start. |
| `connections[].weight_percent` | integer | **percent**, 0–100 | sender load-balancer `weight_percent` | Current load-balancing weight (100=optimal … 10=critical). |
| `connections[].window` | integer | **packets** (signed `int32`) | wire `window` | Congestion window size. |
| `connections[].in_flight` | integer | **packets** (signed `int32`) | wire `in_flight` | Unacknowledged packets currently in flight. |
| `connections[].bitrate_bps` | integer | **bits per second**, ≥ 0 | wire `bitrate_bytes_per_sec` × 8 | Per-link throughput. **Unit conversion is mandatory:** the wire field is *bytes*/s; the JSON field is *bits*/s (multiply by 8). e.g. wire `312500` B/s → JSON `2500000` bps (= 2500 kbit/s). |

> **Required by the gate** (the four fields every downstream task must rely on):
> top-level `connections` and `last_updated_ms`; per-connection `conn_id`,
> `rtt_ms`, `nak_count`, `weight_percent`. `window`, `in_flight`, and
> `bitrate_bps` are included for completeness and round-trip fidelity with
> `connection_info_t`.

### Canonical example (parses cleanly)

```json
{
  "last_updated_ms": 1749556546000,
  "connections": [
    {
      "conn_id": "0",
      "rtt_ms": 42,
      "nak_count": 3,
      "weight_percent": 85,
      "window": 8192,
      "in_flight": 100,
      "bitrate_bps": 2500000
    },
    {
      "conn_id": "1",
      "rtt_ms": 73,
      "nak_count": 11,
      "weight_percent": 55,
      "window": 4096,
      "in_flight": 240,
      "bitrate_bps": 1200000
    }
  ]
}
```

### Empty example (zero active links — running but idle)

```json
{
  "last_updated_ms": 1749556546000,
  "connections": []
}
```

## Behaviors

### Zero Active Links

`srtla_send` is running but has no active uplinks. The producer **still writes**
a snapshot with `"connections": []` and a current `last_updated_ms`. The binding
returns `{ last_updated_ms, connections: [] }`. The UI renders its empty/"no
links" state — explicitly *not* an error, and explicitly *not* the same as
"telemetry absent".

### Stale Data (threshold: **5000 ms** / 5 s)

Define `SENDER_TELEMETRY_STALE_MS = 5000`. With a 1000 ms write cadence this
tolerates ~5 consecutive missed writes before a snapshot is judged dead — long
enough to ride out a scheduling hiccup, short enough that a wedged or crashed
`srtla_send` is caught within ~5 s (and the sender's own 15 s `CONN_TIMEOUT` has
not yet fired).

A snapshot is **stale** when `Date.now() - last_updated_ms > 5000`. On stale
data the binding **does not throw**; it surfaces the snapshot as stale (e.g.
returns the parsed object with a `stale: true` marker, or `null`, per the
binding's typed contract — Task 19/21 decide the exact shape, but the threshold
is fixed here). Consumers treat stale telemetry as "no fresh data" and fall back
to the empty/unknown state rather than displaying frozen numbers as if live.

### File / Socket Absent

The stats file does not exist — *our* `srtla_send` was never started on this
port, a **stock/upstream sender** is running (which never writes this file), or
the file was removed. The binding returns **`null`**, never throws. Because
telemetry exists **only for our sender**, `null` is the normal, expected signal
that drives the UI empty state — stock senders simply yield no data. A
malformed/truncated read (which atomic `rename` should make impossible, but the
binding still guards against defensively) is caught and likewise returns `null`.

## Testing Implications

- **Binding unit tests (Bun, fixture-driven):** drop fixture files and assert
  the reader's output for each case — full snapshot parses to typed records;
  empty `connections: []` yields the idle state; an old `last_updated_ms`
  triggers the 5000 ms staleness path; **absent file → `null`**; malformed JSON
  → `null` (never throws). No live `srtla_send` required.
- **Producer tests (srtla ctest, C/C++):** start `srtla_send`, attach a link,
  and assert the stats file appears at `/tmp/srtla-send-stats-<port>.json`,
  contains JSON parseable against this schema, refreshes within the write
  interval, and collapses to `"connections": []` when links drop. The existing
  63-test ctest suite must stay green.
- **Atomicity guarantee:** a reader in a tight loop against a continuously
  rewriting producer must **never** observe malformed/torn JSON — this is the
  property that justifies choosing Option A and is directly testable.
- **Schema conformance / gate:** the canonical example above must parse via
  `bun -e 'JSON.parse(await Bun.stdin.text())'`. The additive Zod schema (Task
  19) mirrors this table exactly and is the shared contract Tasks 18/19/21/22
  validate against — schema drift between the C producer and the TS consumer is
  a release blocker.
- **Stock-sender path:** a test that runs without our producer confirms the
  binding returns `null` and the UI shows the empty state (no thrown error, no
  crash).

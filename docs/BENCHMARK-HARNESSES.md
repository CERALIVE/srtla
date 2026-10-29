# H1 relay capacity and G5 sender DNS

[EXISTS] Deterministic fixtures, H1 process/NIC capture and G5 isolated wire
capture. No sender or receiver source is changed. Real modes create local
processes/listeners and G5 creates disposable namespaces; neither creates
provider resources or publishes DNS. The Miami campaign remains owner-gated.

```bash
bash tests/compat/scenarios/capacity-probe.sh --selftest
bash tests/compat/scenarios/sender-dns.sh --selftest
bash tests/compat/scenarios/capacity-probe.sh --fixture capacity.json --output verdict.json
bash tests/compat/scenarios/sender-dns.sh --fixture dns.json --output verdict.json
```

Choose a new repo-local results directory for each run. Output files must not
already exist. Exit 0 means the fixture evidence is sufficient to evaluate, not
that live qualification passed; exit 1 means insufficient evidence or no safe
capacity; exit 2 means invalid input or an output error. Without `--fixture` or
`--selftest`, both scripts emit a JSON SKIP reason and exit **77** unless an
explicit real mode and configuration are selected. Real modes use the same
exclusive-output rule, retain raw capture in a sibling `*-artifacts` directory,
and distinguish unavailable prerequisites (77, named reason), a failed or
insufficient experiment (1), and invalid input/runtime failure (2).

Every fixture verdict includes `source: fixture`, `qualified: false`, the raw observations,
`input_sha256` over input bytes and `rule_sha256` over the evaluator's versioned
rule. Never copy fixture capacity into production configuration. Fixture G5 always emits
`dual_stack_safe: false`: even a synthetically safe result is only
`fixture_dual_stack_safe: true`. Publishing AAAA requires the owner's real campaign,
not these selftests. Real phone apps remain `UNVERIFIED` with a reason.

## H1 input contract

The executable fixtures in `tests/compat/lib/test_benchmark_harnesses.py` are the
complete example inputs; `capacity_fixture()` creates a full nine-cell matrix.
JSON input has:

- `schema_version: 1`, `source: fixture`, `provider_class` (e.g. `fixture:relay`),
  `sender_ref: main`, `receiver: stock`.
- Measured sustainable ceilings `sustainable_nic_mbps: {in, out}`,
  `sustainable_pps: {in, out}` and positive `per_bond_pps_6mbps`.
  Both directions must be supplied; the smaller ceiling bounds the formula.
- `cells`: unique `(bonds, bitrate_mbps, links)` observations. Bonds are 1–200,
  bitrates are 6/10/20 Mbps, links are 1/4/16. Each cell supplies:
  `duration_s`, peak `per_core_cpu_pct` array, `receiver_core` index,
  peak `nic_in_mbps`, `nic_out_mbps`, `pps_in`, `pps_out`, `sls_cpu_pct`,
  `delivered_goodput_mbps`, `baseline_goodput_mbps`, and window counts
  `auth_failures`, `evictions`, `disconnects`.
- Sample arrays with at least three evenly spaced samples covering the same
  window: `packets_received` (`srtla_packets_received_total`), `recv_batches`
  (`srtla_recv_batches_total`), `udp_receive_errors`, `rss_bytes`,
  `stock_rss_bytes` and `fd_count`. Stock RSS must use the same window and load.
  Counter resets and empty receive intervals invalidate the input.
- `preview_trials`: unique `{transcodes, duration_s, cpu_pct, minimum_fps}`.
  `cpu_pct` is the busiest core's peak; `minimum_fps` is the slowest preview.

A cell needs at least 30 minutes, every CPU core <70%, NIC Mbps and pps ≤60%
of their directional sustainable ceilings, no auth failures/evictions/disconnects
or UDP-error delta, and delivered goodput within 5% of its stock baseline.
Monotonic RSS growth must not exceed stock's absolute growth over that same
window; flat RSS passes. Counters must be measured over the window, not assumed
zero from process startup.

The bond-count result is the greatest count whose **entire nine-cell matrix**
passes; a missing or failing cell cannot be treated as a passing configuration.
The integer capacity is:

```text
softCapBonds = floor(min(bond-count result,
                        0.6 * min(sustainable NIC in,out Mbps) / 6,
                        0.6 * min(sustainable pps in,out) / per-bond pps at 6 Mbps))
maxAssignedRelays = 2 * softCapBonds
```

The formula uses exact decimal fractions before flooring. The verdict retains
all cells, per-check results, interval recvmmsg fill ratios, RSS slopes and fd
peaks, including cells that fail. `cpu_bound` requires a receiver core ≥85%,
strictly increasing interval fill ratios, NIC ≤60% and SLS CPU <70%. It does not
authorize extra receiver processes. The fixture preview cap is the largest
observed concurrency sustaining ≥9.5 fps (5% tolerance around the 10 fps target)
for 30 minutes with CPU <70%; it does not change `PREVIEW_TRANSCODE_MAX`.

## G5 input contract

`dns_fixture()` in the test file supplies all four sender fixtures:
`c-srtla-send`, `moblin-mock`, `srtla-send-rs`, `ceraui-resolveSrtla`.
The mock follows the existing matrix pin
`0ae5294950166978064840bc874bfed3a8cf03a4`; the Rust sender remains unchanged.
These labels describe simulated observations, not executions of those senders.

- Top level: `schema_version: 1`, `source: fixture`, `nodes` and `observations`.
- `nodes` maps one-label `g<N>-<location>` identities to `{a, aaaa}` literal IPs.
  Addresses must be unique. This is fixture identity data, not a DNS publish list.
- Each observation supplies `sender`, `scenario`, `hostname`, `resolver_queries`
  (resolver identifiers from the query capture), and `uplinks`. Every uplink
  supplies a unique `namespace`, its own unique `resolver`, a selected literal
  `address` and `cname_chain` (the resolved target node identity).
- All seven scenarios are required for each sender: `control` (shared geo name),
  `per_relay` (one CNAME to one node A), `stale_cache`, `a_only`, `aaaa_only`,
  `dual_stack` (divergent A/AAAA node choices) and `nat64`. There must be at
  least two uplinks per observation. Names outside the control use
  `r-<10 lowercase alphanumeric characters>.ingest.<domain>`, never a node URL.

Different control destinations with queries at multiple resolvers classify
`per_network`. One observed resolver query and identical selected addresses
classify `resolve_once`; other evidence stays `unknown`. Identical per-relay A
answers must be present for every sender. Observations with the same per-relay
hostname form one steady-state experiment: their address union across senders
must contain exactly one address, or `per_relay_single_answer` is false and the
winner is `insufficient`. Different hostnames are evaluated separately.
Stale-cache node divergence is retained
as `split_during_change`, never silently passed. Missing scenarios or absent
control/stale-cache detection yield `winner: insufficient`.

Dual-stack decisions compare server identity rather than unequal IPv4/IPv6
strings. A-only and AAAA-only must use the correct family, the dual-stack case
must exercise both families, and NAT64 must include a `64:ff9b::/96` synthesized
address whose embedded IPv4 identifies a known node. Each case must reach one
server across all uplinks. Divergent A/AAAA placement fails this check. Unknown
addresses, multiple CNAME hops and duplicate observations are invalid, not passes.

IRL Pro, Larix, OBS SRTLA forks and real BELABOX devices require separate
owner-operated evidence. H3/H4/H5/H7 and relay-to-OBS RTT are outside this harness.

## H1 real-host capture

```bash
bash tests/compat/scenarios/capacity-probe.sh --real-host \
  --config tests/compat/results/h1-config.json \
  --output tests/compat/results/h1-verdict.json
```

The runner measures the configured interface's Linux byte/packet counters.
It runs a UDP iperf3 offered-load sweep with 1316-byte datagrams, in each direction, against an **already
authorized** peer (`iperf3 -s -p 43000`). Only loss-bounded delivered Mbps and
pps, capped by the observed NIC counters, enter the formula. These are
conservative measured lower bounds, not advertised line rate. Choose enough
offered rates to find the sustainable limit; record an unsaturated sweep as a
lower bound. Isolate unrelated traffic and retain the peer's provenance.

For each requested bond count (1..200), the runner executes the entire
6/10/20 Mbps by 1/4/16 link matrix. Each cell first runs a separate stock
baseline with the same load and window, then captures the measured run. It
launches one unchanged sender and media caller per bond, one stock receiver,
the real SLS command, and one output reader per bond. The reader writes
delivered transport-stream bytes to `{media_file}`. No forwarding counter is
substituted for delivered application goodput.

Capture includes sampled `/proc/stat` per-core CPU, `/proc/net/dev` NIC bytes/packets,
`/proc/net/snmp` UDP errors, receiver RSS/fds, SLS process CPU, and the stock
receiver's Prometheus counters. Receiver affinity is fixed to `receiver_core`.
`/proc/net/dev` observes the collector's current network namespace, unlike a
sysfs mount inherited from the host. SLS CPU is conservatively its whole process load, capped at 100%; it is not an
inferred GPU or per-worker measurement. Peak sampled loads and all raw snapshots
are retained. Real `cpu_bound` also requires measured receiver-process CPU
at least 85%, so an unrelated busy process on its pinned core cannot supply
the scaling signal. Preview commands must emit ffmpeg `-progress pipe:1` frame
counters; the cap uses the busiest sampled CPU interval and slowest actual
frame-rate interval of every preview, not the requested output frame rate.
Media callers must also emit `total_size` progress counters. Real cells check
measured offered media against `bonds * bitrate_mbps` within 5%, so a nominal
20-Mbps command that actually sends 2 Mbps cannot establish a 20-Mbps capacity.

Required configuration is schema version 1:

```json
{
  "schema_version": 1,
  "provider_class": "local:loopback-smoke",
  "interface": "lo",
  "sender_ref": "main",
  "sender_sha": "<actual 40-character main source SHA>",
  "receiver": "build/srtla_rec",
  "receiver_core": 0,
  "port_base": 43100,
  "duration_s": 1800,
  "samples": 31,
  "bonds": [1, 25, 50, 100, 150, 200],
  "link_addresses": ["<16 configured source addresses>"],
  "calibration": {
    "host": "<authorized peer IP>", "port": 43000, "duration_s": 30,
    "offered_mbps": [100, 300, 500, 1000], "maximum_loss_pct": 0.1
  },
  "sender": {"argv": ["srtla_send",
    "{local_port}", "127.0.0.1", "{receiver_port}", "{ips_file}"]},
  "sls": {"argv": ["<SLS executable>", "<its existing arguments>"],
    "ready": "<its actual ready log marker>"},
  "sink": {"argv": ["<output reader>", "<stream {bond}>", "{media_file}"]},
  "load": {"argv": ["<media caller>", "<stream {bond} at {bitrate_mbps} Mbps>",
    "<local SRT port {local_port}>"], "ready": "<actual first-media marker>"},
  "preview": {"counts": [1, 2, 4],
    "argv": ["<preview executable>", "<input>", "-progress", "pipe:1",
      "<output for {index}>"]}
}
```

Command arrays are executable boundaries, not shell snippets or metric
providers. Replace the angle-bracket fields with the deployed applications'
real argv; the input hash binds those templates to the run. Additional substitutions are `{sls_port}`,
`{metrics_port}`, `{directory}` and `{duration_s}`. All service ports must be
43000..43999. `ready` is optional for SLS; load readiness must represent actual
media, not a sleep. Provide 16 real configured source addresses. The current
main Rust sender is built from source, unmodified; `sender_sha` records that
build provenance, and the receiver binary hash is recorded independently.
Commands must keep the measured programs in the foreground. SLS CPU is the
launched process's CPU, not a Docker CLI, a detached daemon or a remote host;
those wrappers are not supported measurement boundaries.

`measurements.json` and the verdict retain the fixture metric field names, but
use `source: real-host`; fixture input still rejects that source. Short local
windows produce measured observations with zero qualified capacity, not a
30-minute pass. Local results always carry `qualified: false`; no command
changes production caps, authorizes a host, or replaces the Miami campaign.

## G5 isolation decision and live capture

```bash
bash tests/compat/scenarios/sender-dns.sh --live \
  --config tests/compat/results/g5-config.json \
  --output tests/compat/results/g5-verdict.json
```

The process tree runs inside an unprivileged user + mount + PID + network
namespace. There is **one sender/application launch per case, not one per
uplink**. Its two veth interfaces lead to two independently caching resolver
namespaces. Both resolvers have the same DNS service address. Source-policy
routes send interface-bound queries through that interface's resolver;
unbound process-wide lookups follow the default uplink. Resolver configuration
and NSS are bind-mounted only in the private mount namespace, so neither host
DNS nor the host resolver daemon is used or changed.

The lab opens its DNS and destination-capture sockets before launching the
sender. A packet's resolver namespace, query bytes, answer bytes, source
address and destination socket identify its path. Minimal registration
responders echo the existing REG1/REG2/REG3 and keepalive wire messages so both
uplinks can become observable. They share a group registry. This is a DNS
destination experiment, **not media, reassembly or native receiver acceptance**.
No device protocol or sender code is modified.
Socket readiness and Linux pidfd exit readiness share one selector; no sender
exit is inferred from a sleep or a periodic process poll.

Source socket inodes from `/proc/net/udp{,6}` are joined to `/proc/<pid>/fd`.
Only one actual sending PID across both paths can be classified, including
when an application launcher has descendants. Unattributed/exited sockets or
two sender children force `unknown`. Known one-process resolve-once and
per-network socket controls calibrate the topology; they are reported
separately as `isolation_controls`, never as product senders. Additional controls
prove the stale-cache split and real DNS64/UDP translation round trip.

CONTROL gives the two resolvers different node A answers. A single process
with different captured destinations and queries at both resolvers is
`per_network`. One target query and the same captured destination on both
uplinks is `resolve_once`. Missing packets, multiple sender instances, repeated
queries without a proven single lookup, or ambiguous evidence remain `unknown`.
In particular, two separately launched resolve-once senders can never prove
per-network behavior.

The per-relay case returns one CNAME to one node A. Stale-cache priming sends
real DNS requests through both paths, changes the authority, and invalidates
only the second cache. Old and new destinations remain in `split_during_change`.
Priming queries are excluded from sender classification and retained in the
raw capture. A/AAAA-only and divergent dual-stack cases retain unsuccessful
resolution/connection attempts, including early sender exit; they are never
converted to selected literal addresses.

The NAT64 arm gives the second path a DNS64 synthesized address and translates
UDP payload/reply traffic through an actual per-client IPv6/IPv4 socket mapping.
This covers this UDP destination decision, not carrier NAT64 ICMP,
fragmentation, MTU or arbitrary transport behavior. `dual_stack_safe` requires
all four real senders, two observed paths and one node in every family case,
both families in the divergent dual-stack case, and a synthesized destination
plus translated IPv4 traffic in NAT64. Missing/failed cases keep it false.
Review this bounded UDP evidence before any separate publication decision.

### Sender execution boundaries

The config's `senders` map has these names and boundaries:

| Name | `boundary` | Actual command |
|---|---|---|
| `c-srtla-send` | `bonded-process` | `build/srtla_send {local_port} {hostname} {receiver_port} {ips_file}` |
| `srtla-send-rs` | `bonded-process` | unchanged main binary, same positional CLI |
| `moblin-mock` | `sequential-rebind` | existing pinned Python mock, `--bind-ip {ip0} --ip-change-to {ip1} --ip-change-at-sec 0`, plus receiver/local-port arguments |
| `ceraui-resolveSrtla` | `application-cache` | built-in Bun probe imports the actual helper/cache, then starts ONE unchanged bonded sender |

The Moblin mock takes only one active interface, then rebinds within the same
process after registration. The capture reports that boundary, not simultaneous
native Moblin paths. It does not justify translating mock system-resolver
behavior into Apple's network-scoped resolver behavior.

CeraUI is not a standalone libc resolver. Its actual `resolveSrtla` calls
`dnsCacheResolve`, validates answers asynchronously, queues gateway updates,
and may return a hostname on a fresh answer but a literal from its persistent
cache. The built-in `ceraui-resolver-probe.mjs` imports the configured real
module with its actual cache in a private per-case working directory, calls the
helper twice in that same application process, records both returned choices,
and passes the cold return unchanged to one bonded sender. It does not assert
that a warm call must hit the cache: the application's validation/cache policy
decides that. The lab also answers CeraUI's real well-known DNS validation
request. Do not replace the helper with `getaddrinfo`, an extracted function,
or a mock cache. Record the application source SHA.
The CeraUI entry uses `helper_module`, `setup_file`, `sender_binary` and optional `bun`
instead of `argv`; missing files/dependencies are named prerequisites. The
module and installed application dependencies must be available as repo-local
source/build inputs. An absent application entry is explicitly `UNVERIFIED` with
`missing_sender_command:ceraui-resolveSrtla`; it is not a synthetic pass.
The supplied unchanged boot setup is copied into the private working directory.
Production DNS code runs with mocks disabled. `CERALIVE_DEVICE_TYPE=emulated`
prevents gateway/device-control side effects; it does not replace the helper,
its DNS resolver or cache. This measures the actual helper/cache on a host,
not full CeraUI device startup.

Example configuration for a real, deliberately partial C-sender campaign:

```json
{
  "schema_version": 1,
  "requested": ["c-srtla-send"],
  "timeout_s": 8,
  "receiver_port": 43060,
  "senders": {
    "c-srtla-send": {
      "boundary": "bonded-process",
      "argv": ["build/srtla_send", "{local_port}", "{hostname}",
        "{receiver_port}", "{ips_file}"]
    }
  }
}
```

Omit `requested` for all four senders. Missing commands produce an aggregate
77 with explicit names **after** retaining available real observations.
Selecting a subset completes those observations only; `complete` remains false
and unrequested senders stay UNVERIFIED. An observed unsafe family is a result,
not a missing prerequisite or a SKIP. Every case retains its process identity,
argv, source SHA, resolver queries, captured packets, per-path selected address
or absence, and exit/deadline evidence. Real verdicts have `source: live`.
All processes are reaped and namespace descriptors closed before return;
kernel namespace lifetime removes their interfaces and private mounts.

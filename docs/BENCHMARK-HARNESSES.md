# H1 relay capacity and G5 sender DNS

[PARTIAL] The deterministic evaluators and fixture tests exist. Live capacity,
provider, packet capture and per-uplink namespace execution remain owner-gated.
No sender binary or receiver source changes are needed. These commands do not
create listeners, namespaces, provider resources or DNS records.

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
`--selftest`, both scripts emit a JSON SKIP reason and exit **77**, including
H1 `--real-host` and G5 `--live`. No environment flag bypasses this gate.

Every verdict includes `source: fixture`, `qualified: false`, the raw observations,
`input_sha256` over input bytes and `rule_sha256` over the evaluator's versioned
rule. Never copy fixture capacity into production configuration. G5 always emits
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

# compat harness libraries

Sourceable helpers shared by the SRTLA compat scenarios. Each is a plain bash
library: `source` it, call its functions, and let its EXIT trap clean up.

## `netem.sh` — veth + netns + tc-netem network shaping

Provides deterministic, single-leg network shaping for the latency suites
(jitter, delay, reorder, loss). It is the Wave-1 dependency under the latency
scenarios.

| Function | Purpose |
|----------|---------|
| `netem_require` | Capability gate. Returns `77` (SKIP-PRIVILEGED) if not privileged. Call it first. |
| `netem_setup <name> [netem args]` | Create `ns-srtla-<name>` + a veth pair, park the peer in the netns, shape the host end with `netem <args>` (no args = passthrough). Idempotent. |
| `netem_change <name> <netem args>` | Live-replace the netem discipline (phase transitions). |
| `netem_teardown <name>` | Drop qdisc + veth + netns. Idempotent — safe to call repeatedly. |
| `netem_teardown_all` | Reap every instance this process created. |
| `netem_selfcheck` | Measure the RTT delta under `delay 100ms`; PASS iff the delta lands in `[90,130]`. |

CLI form (selfcheck / probing / ad-hoc shaping):

```bash
sudo tests/compat/lib/netem.sh selfcheck      # exit 0 on PASS, 77 if unprivileged
sudo tests/compat/lib/netem.sh require
sudo tests/compat/lib/netem.sh setup    mylink delay 80ms 10ms
sudo tests/compat/lib/netem.sh teardown mylink
```

### Why veth + netns, not loopback

`netem` on `lo` shapes both legs of a round trip, so `delay 100ms` becomes a
~200ms RTT — a 2× artifact that quietly corrupts latency assertions. A veth pair
with its far end in a private netns crosses the shaped qdisc once per direction;
shaping a single end makes RTT delta ≈ the configured one-way delay.

### CI capability verdict

`netem.sh` needs `CAP_NET_ADMIN` (real root, or mapped-root in a user+net
namespace) plus `ip`, `tc`, `ping`. `netem_require` probes this functionally.

- **GitHub Actions `ubuntu-latest` — CAPABLE.** Runners provide passwordless
  `sudo` and full VM root; veth / `ip netns` / `tc netem` are all available (the
  `compat-matrix.yml` workflow already uses `sudo apt-get`). Latency scenarios
  must run their netem steps under `sudo` there.
- **Unprivileged shells — clean skip.** `netem_require` prints a
  `SKIP-PRIVILEGED:` line and returns `77`, mirroring `pcap-replay`'s exit-77
  SKIP semantics. No partial state is created.
- **Local dev without passwordless sudo.** Exercise the identical code path via
  a mapped-root namespace:

  ```bash
  unshare -rnm bash -c 'mount -t tmpfs none /run; mkdir -p /run/netns; \
                        exec bash tests/compat/lib/netem.sh selfcheck'
  ```

  The tmpfs `/run` shim only gives `ip netns` a writable directory; the library
  source is byte-identical to the real-root path.

### Trap contract

Sourcing (or executing) `netem.sh` arms an EXIT/INT/TERM trap that runs
`netem_teardown_all`, so no qdisc or veth ever leaks — including on a raw
SIGTERM. A scenario that installs its **own** master trap *after* sourcing
`netem.sh` overrides ours and **must** call `netem_teardown_all` from its own
cleanup handler (the same way `link-drop.sh`'s `cleanup` reaps its resources).

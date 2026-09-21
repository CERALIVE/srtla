# srtla (C receiver)

Parent: [`../AGENTS.md`](../AGENTS.md)

## ROLE IN THE GROUP

CERALIVE's **hard fork** of [`irlserver/srtla`](https://github.com/irlserver/srtla), the
C++ SRTLA bonding **receiver** (`srtla_rec`). It accepts a sender's bonded uplinks,
reassembles the SRT stream and forwards it to a downstream SRT listener (in our stack,
`irl-srt-server`). The device-side sender is **not** this repo: it is the Rust
[`srtla-send-rs`](https://github.com/CERALIVE/srtla-send-rs). This repo is
**receiver-only, release-free, and source-byte-identical to upstream.**

What CERALIVE adds, and nothing else:

- `CMakeLists.txt`: `install(TARGETS srtla_rec …)` only, `add_subdirectory(tests)`,
  the `BUILD_COMPAT_TESTS` option.
- `tests/`: the GTest handler harness and the compat/A-B harness (`tests/compat/`).
- `.github/`: `build-check.yml`, `static-analysis.yml`, `compat-matrix.yml`,
  `.github/actions/compat-build`, plus upstream's own `build-and-push.yml` untouched.
- `docs/`: receiver docs and the historical ADR-002; `.clang-tidy`.

## UPSTREAM RELATIONSHIP

Fork base: upstream `b8359bc80ce99ac4fc8f603cfa455cdd0a0a4241`, which is also the
last-merged upstream SHA; the next sync's merge base is computed from it. The invariant
that every PR must keep:

```bash
git diff --stat b8359bc80ce99ac4fc8f603cfa455cdd0a0a4241..HEAD -- src/   # prints nothing
```

Only one permanent remote, `origin` (`CERALIVE/srtla`). Upstream is a **transient**
remote named `irlserver`: add, fetch with an explicit refspec, pin-verify the SHA, merge
with a true merge commit, remove the remote before any push or PR. Merges are **manual
and deliberate**; no auto-sync, no bots, no scheduled update PRs. `compat-matrix.yml`'s
weekly `upstream-drift` job only *reports* new upstream commits; it changes nothing.

A behaviour change to the receiver goes upstream first, or ships as a build-time patch
under `tests/compat/patches/` while it is being measured. It does not land in `src/`.
The D21 keepalive-cadence patch is the model: `git apply --check` passes forward and
fails in reverse, and CI checks exactly that.

## BUILD / GATE

```bash
git submodule update --init                       # deps/argparse
cmake -B build && cmake --build build
ctest --test-dir build --output-on-failure        # GTest harness
cmake --install build --prefix /tmp/p && ls /tmp/p/bin   # must print: srtla_rec
bash tests/workflow-contracts.sh && bash tests/workflow-contracts-negative.sh
bash tests/compat/run-matrix.sh --validate-only
python3 tests/compat/lib/ab-verdict.py --selftest
```

`-DSRTLA_BUILD_TESTS=OFF` is what the clang-tidy lane uses. `-DBUILD_COMPAT_TESTS=ON`
builds `srt-sink` and `ext-ka-probe` for the compat scenarios. The receiver sources are
CRLF; generate patches against them with byte I/O or you get a whole-file diff.

Tests compile against upstream `src/` **unmodified**. A test that needs a fork-only seam
(fake clock injection, identity hooks, the C sender's decision logic, sender telemetry)
is dropped, and the drop list with the reason for each is a comment block at the end
of `tests/CMakeLists.txt`. Do not "fix" one of those by growing `src/`.

## CI

| Workflow | Jobs | Notes |
|---|---|---|
| `build-check.yml` | AMD64 + ARM64 build, `ctest`, `Verify receiver-only install` | bounded ccache, revision-keyed |
| `static-analysis.yml` | `clang-tidy` (runs both contract scripts first), `test` | `-DSRTLA_BUILD_TESTS=OFF` for tidy |
| `compat-matrix.yml` | `harness-selftest`, `hosted-jitter`, `generate-matrix`, `compat-blocking` + gate, `compat-informational` + gate, `pcap-replay`, `upstream-drift` | matrix generated from `matrix.yaml` |
| `build-and-push.yml` | GHCR `ghcr.io/ceralive/srtla:<sha>` + `:latest` on push to `main` | upstream's file, byte-identical |

The canonical and default branch is `main`; the former canonical history is retained
on `legacy`. All three gate workflows filter pushes and pull requests to `[main]`.
There is no `ci.yml`: the build gate is `build-check.yml` (display name `Build Check`).
`tests/workflow-contracts.sh` asserts
the workflow shapes (ccache bound and keys, permissions, job graph, the hosted-jitter
provenance pins); the negative script mutates each assertion and requires it to fail.
Do not weaken a job to get green, and do not add a workflow that publishes anything.

## COMPAT HARNESS (`tests/compat/`)

- `matrix.yaml` is the **single registry**: senders, receivers, pairs, scenarios,
  `ab_campaigns`, `invariants`. Every entry is addressed by exactly one of `pin:`
  (40-hex, third-party, immutable) or `ref:` (a CERALIVE canonical branch or published
  release tag). `validate-matrix.py` enforces the rule and the declared pair
  counts; `gen-ci-matrix.sh` feeds CI and marks each build `immutable: true|false`.
- The CERALIVE sender pair is built **from source** at its `ref`. This repo consumes no
  sender release artifact and no `.deb`; if a sender ref resolution fails in CI the fix
  is the ref in `matrix.yaml`, never a skipped job.
- The sender registry and Dockerfile default use `CERALIVE/srtla-send-rs` `main`;
  the libsrt registry and build-helper default use `srt-v1.5.7+ceralive.2`.
  Completed A/B scenario documents and evidence retain their original branch names,
  SHAs and frozen rules as historical provenance, not current build defaults.
  The hosted-jitter lane's exact legacy SHA pins are likewise unchanged.
- Two **pre-registered A/B campaigns** live in `scenarios/ab-periodic-nak.yaml` (D10:
  `SRTO_PERIODICNAKGATE=1` filter vs `=2` suppress on the receiver-side libsrt) and
  `scenarios/ab-keepalive-cadence.yaml` (D21: upstream recovery-keepalive cadence vs the
  legacy patch). Each carries a frozen `rule:`; `lib/ab-verdict.py` is the **only**
  implementation of the decision, `--selftest` checks the code's thresholds against the
  prose, and `--print-rule` exists so the rule can be diffed against its source. They
  are not run by CI: one campaign at a time, on a quiesced bench host, with the disk
  floor checked first. Never edit a `rule:` after data exists.
- `lib/sender-log-metrics.py` extracts the D21 metrics from a sender debug log;
  `lib/build-libsrt-matrix.sh` builds vanilla and CERALIVE libsrt side by side for
  `srt-sink`'s `SINK_LD_LIBRARY_PATH`. `srt-sink` addresses the CERALIVE options by
  **numeric id** (118/119/120) so it compiles against stock libsrt headers and reports
  `unsupported` at runtime. Gate a `REORDERFREEZE` arm on the *readback*, not the banner.
- Privileged scenarios (`netem`) exit 77 to self-skip without `CAP_NET_ADMIN`.

## DOCS

| File | Content |
|---|---|
| `docs/HOW_IT_WORKS.md` | protocol, registration handshake, extended keepalive, quality model, timeouts |
| `docs/NETWORK_SETUP.md` | source routing and the ips file on the **sender** host |
| `docs/TROUBLESHOOTING.md` | failure modes, diagnostics, metrics |
| `docs/COMPATIBILITY.md` | ecosystem table, wire consensus, known issues, guarantees |
| `docs/adr/ADR-002-srt-patch-necessity.md` | historical srt-patch A/B; banner points at D10 |
| `docs/keepalive-improvements.md`, `docs/connection-info-comparison.md` | upstream design notes, untouched |

Rule A: a behaviour or structure change updates `AGENTS.md` and `README.md` in the
same PR. `README.md` is upstream's text plus one appended `CERALIVE layer` section; edit
only that section.

## ANTI-PATTERNS

- **No edits to `src/`.** The byte-identity check above is the PR gate. Ports of
  receiver behaviour go upstream or into `tests/compat/patches/`.
- **No releases.** No `v*` tags, no GitHub releases, no `.deb`, no tarballs, no
  checksum files, no `publish-*` workflow. Consumers build from a git ref. Do not bump
  `project(srtla_rec VERSION …)`; there is nothing to version.
- **No C sender packaging.** The `srtla_send` target builds because upstream builds it;
  it is never installed, never packaged, never given a systemd unit. The sender is
  `srtla-send-rs`.
- **No TypeScript (or any other language) wrapper package** in this repo, and no npm
  publish. The sender's helper layer lives with the sender's consumer, not here.
- **No sender telemetry, sd_notify, structured lifecycle log markers, or identity
  hooks.** Upstream ships Prometheus (`--metrics_port`); use that.
- **No auto-sync with upstream**, and never leave the `irlserver` remote attached at
  push or PR time.
- **No scheduler or quality-evaluator tuning** (RTT tiers, jitter scoring, cadence
  changes) outside a pre-registered A/B on the harness. Upstream's evaluator was
  IRL-tested against upstream's sender; it stays verbatim until measured.
- **No CalVer, no version bumps of any kind** on this repo.
- **No path above the repo root in any tracked file.** CI runs this repo standalone.
- `.omo/` and the `build*` directories are untracked scratch; stage with explicit
  `git add <path>`, never `git add -A`.

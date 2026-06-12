#!/usr/bin/env bash
#
# netem.sh — sourceable veth + netns + tc-netem network-shaping library for the
#            SRTLA compat harness (Wave 1 infrastructure for the latency suites).
#
# WHY veth + a dedicated netns (NOT raw loopback):
#   netem on `lo` shapes BOTH legs of a round trip, so `delay 100ms` shows up as
#   a ~200ms RTT — a 2x artifact that silently corrupts every latency assertion.
#   A veth pair with its far end parked in a private network namespace makes a
#   ping cross the shaped qdisc once per direction; applying netem to ONE end
#   yields an RTT delta ~= the configured one-way delay. Measured on this stack:
#   bare veth ~0.03ms, `delay 100ms` -> ~100ms RTT (delta in [90,130]).
#
# TOPOLOGY (per named instance <name>):
#       host ns                         ns-srtla-<name>
#   .---------------.   veth pair   .--------------------.
#   | veth-srtla-S *|---------------|* npeer-S           |
#   |   10.173.N.1  |               |   10.173.N.2       |
#   '---------------'               '--------------------'
#       ^ netem applied here (one end)         ^ ping target
#   S = short slug of <name>; N = deterministic /30 octet from <name>.
#   Only the host-side iface is visible to the host `ip link show`, so the
#   residue grep (`ip link show | grep -c veth-srtla`) is meaningful and exact.
#   Linux caps interface names at 15 chars (IFNAMSIZ): the host iface is
#   `veth-srtla-<slug>` with slug<=4; longer <name>s fall back to a hash slug.
#
# PRIVILEGE / CI CAPABILITY VERDICT:
#   Needs CAP_NET_ADMIN (real root, or mapped-root in a user+net namespace) plus
#   `ip`, `tc`, `ping`. `netem_require` probes this functionally and is the gate
#   every consumer must call first.
#     * GitHub Actions `ubuntu-latest`: CAPABLE. Runners give passwordless
#       `sudo` and full VM root; veth / `ip netns` / `tc netem` are all present
#       (the compat-matrix workflow already uses `sudo apt-get`). Scenarios that
#       layer on this lib must run their netem steps under sudo there.
#     * Unprivileged shells: `netem_require` prints a SKIP-PRIVILEGED line and
#       returns 77 — callers treat 77 as a clean skip, mirroring pcap-replay's
#       exit-77 SKIP semantics. No partial state is created.
#     * Local dev without passwordless sudo: exercise via a mapped-root
#       namespace, e.g.
#         unshare -rnm bash -c 'mount -t tmpfs none /run; mkdir -p /run/netns;
#                               exec bash tests/compat/lib/netem.sh selfcheck'
#       The tmpfs `/run` shim only gives `ip netns` a writable dir; the library
#       code path is byte-identical to the real-root one.
#
# PUBLIC API (source this file, then call):
#   netem_require                    capability gate; returns 77 if unprivileged
#   netem_setup    <name> [args...]  create veth+netns, shape the host end with
#                                    `netem <args>` (no args = bare passthrough)
#   netem_change   <name> <args...>  live-replace the netem discipline
#   netem_teardown <name>            idempotent: drop qdisc + veth + netns
#   netem_teardown_all               tear down every instance THIS process made
#   netem_selfcheck                  measure RTT delta under `delay 100ms`
#
# TRAP CONTRACT:
#   Sourcing (or executing) this file arms an EXIT/INT/TERM trap that runs
#   `netem_teardown_all`, so nothing leaks on any exit path — including a raw
#   SIGTERM. A scenario that installs its OWN master trap AFTER sourcing this
#   file overrides ours; such scenarios MUST call `netem_teardown_all` from
#   their cleanup handler.
#
# Rule D: writes nothing outside the repo and resolves no `../`-escaping path.
#
# Usage as a CLI (for selfcheck / capability probing / ad-hoc shaping):
#   tests/compat/lib/netem.sh selfcheck
#   tests/compat/lib/netem.sh require
#   tests/compat/lib/netem.sh setup    <name> [netem args...]
#   tests/compat/lib/netem.sh change   <name> <netem args...>
#   tests/compat/lib/netem.sh teardown <name>

# Guard against double-sourcing (re-arming traps, clobbering state).
if [[ -n "${_NETEM_SH_LOADED:-}" ]]; then return 0 2>/dev/null || exit 0; fi
_NETEM_SH_LOADED=1

# --------------------------------------------------------------------------- #
# Tunables / state                                                            #
# --------------------------------------------------------------------------- #
: "${NETEM_SUBNET_BASE:=10.173}"   # /30 islands live under 10.173.N.0/30
: "${NETEM_PING_COUNT:=10}"        # samples per RTT measurement
: "${NETEM_PING_INTERVAL:=0.1}"    # seconds between samples (root may go <0.2)
: "${NETEM_PING_TIMEOUT:=2}"       # per-ping deadline (must exceed the delay)
: "${NETEM_SELFCHECK_DELAY_MS:=100}"
: "${NETEM_SELFCHECK_MIN_DELTA:=90}"
: "${NETEM_SELFCHECK_MAX_DELTA:=130}"

# Names of instances created by THIS process (drives teardown_all + the trap).
_NETEM_INSTANCES=()

_netem_log()  { printf 'netem: %s\n' "$*" >&2; }
_netem_skip() { printf 'SKIP-PRIVILEGED: requires root and tc/ip tools (%s)\n' "$*" >&2; }

# --------------------------------------------------------------------------- #
# Pure name -> resource derivations (no shared state; teardown is stateless).  #
# --------------------------------------------------------------------------- #
_netem_sanitize() { # <name> -> safe, length-capped token for the netns name
  local s; s="$(printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_')"
  printf '%.40s' "$s"
}

# A <=4-char slug, stable per <name>, that keeps the host iface within IFNAMSIZ.
# Short alnum names are used verbatim (readable in `ip link`); anything longer
# collapses to a deterministic 4-digit hash so concurrent instances stay unique.
_netem_slug() {
  local n; n="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9')"
  if [[ -n "$n" && "${#n}" -le 4 ]]; then
    printf '%s' "$n"
  else
    printf '%04d' "$(( $(printf '%s' "$1" | cksum | cut -d' ' -f1) % 10000 ))"
  fi
}

_netem_ns()      { printf 'ns-srtla-%s' "$(_netem_sanitize "$1")"; }
_netem_hostif()  { printf 'veth-srtla-%s' "$(_netem_slug "$1")"; }
_netem_peerif()  { printf 'npeer-%s' "$(_netem_slug "$1")"; }
_netem_octet()   { printf '%s' "$(( $(printf '%s' "$1" | cksum | cut -d' ' -f1) % 250 + 1 ))"; }
_netem_host_ip() { printf '%s.%s.1' "$NETEM_SUBNET_BASE" "$(_netem_octet "$1")"; }
_netem_peer_ip() { printf '%s.%s.2' "$NETEM_SUBNET_BASE" "$(_netem_octet "$1")"; }

# --------------------------------------------------------------------------- #
# Capability gate                                                              #
# --------------------------------------------------------------------------- #
# Functionally probes CAP_NET_ADMIN + the veth and netem kernel features by
# building and tearing down a throwaway veth pair (the exact primitives the lib
# relies on). Self-cleaning, leaves no residue. Returns 0 if capable, 77 if not.
netem_require() {
  local t
  for t in ip tc ping; do
    command -v "$t" >/dev/null 2>&1 || { _netem_skip "missing tool: $t"; return 77; }
  done
  local probe="np$$"
  if ip link add "${probe}a" type veth peer name "${probe}b" 2>/dev/null; then
    if tc qdisc add dev "${probe}a" root netem delay 1ms 2>/dev/null; then
      tc qdisc del dev "${probe}a" root 2>/dev/null
      ip link del "${probe}a" 2>/dev/null
      return 0
    fi
    ip link del "${probe}a" 2>/dev/null
  fi
  _netem_skip "no CAP_NET_ADMIN / veth+netem unavailable"
  return 77
}

# --------------------------------------------------------------------------- #
# Instance registry helpers                                                    #
# --------------------------------------------------------------------------- #
_netem_track()   { local n; for n in "${_NETEM_INSTANCES[@]:-}"; do [[ "$n" == "$1" ]] && return 0; done; _NETEM_INSTANCES+=("$1"); }
_netem_untrack() {
  local kept=() n
  for n in "${_NETEM_INSTANCES[@]:-}"; do [[ -n "$n" && "$n" != "$1" ]] && kept+=("$n"); done
  _NETEM_INSTANCES=("${kept[@]:-}")
}

_netem_valid_name() {
  [[ -n "$1" ]] || { _netem_log "name must be non-empty"; return 1; }
  [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]] || { _netem_log "name '$1' has illegal chars (allowed: A-Za-z0-9_-)"; return 1; }
  return 0
}

# --------------------------------------------------------------------------- #
# Lifecycle                                                                    #
# --------------------------------------------------------------------------- #
# netem_setup <name> [netem args...]
#   Creates `ns-srtla-<name>`, a veth pair, parks the peer in the netns, wires
#   /30 addressing, and shapes the host end with `netem <args>` (empty args ->
#   bare passthrough netem, used as the selfcheck baseline). Re-running for an
#   existing <name> tears the old instance down first, so setup is idempotent.
netem_setup() {
  local name="$1"; shift || true
  _netem_valid_name "$name" || return 2

  local ns host peer host_ip peer_ip
  ns="$(_netem_ns "$name")"; host="$(_netem_hostif "$name")"; peer="$(_netem_peerif "$name")"
  host_ip="$(_netem_host_ip "$name")"; peer_ip="$(_netem_peer_ip "$name")"

  netem_teardown "$name"   # clean slate (idempotent; no-op if absent)

  # Track up-front so a failure mid-build is still reaped by the trap.
  _netem_track "$name"

  if ! ip netns add "$ns" 2>/dev/null; then
    _netem_log "setup '$name': could not create netns '$ns'"; netem_teardown "$name"; return 1
  fi
  if ! ip link add "$host" type veth peer name "$peer" 2>/dev/null; then
    _netem_log "setup '$name': could not create veth pair ($host/$peer)"; netem_teardown "$name"; return 1
  fi
  ip link set "$peer" netns "$ns" 2>/dev/null            || { _netem_log "setup '$name': move peer failed"; netem_teardown "$name"; return 1; }
  ip addr add "${host_ip}/30" dev "$host" 2>/dev/null    || { _netem_log "setup '$name': host addr failed"; netem_teardown "$name"; return 1; }
  ip link set "$host" up 2>/dev/null                     || { _netem_log "setup '$name': host up failed"; netem_teardown "$name"; return 1; }
  ip netns exec "$ns" ip addr add "${peer_ip}/30" dev "$peer" 2>/dev/null || { _netem_log "setup '$name': peer addr failed"; netem_teardown "$name"; return 1; }
  ip netns exec "$ns" ip link set "$peer" up 2>/dev/null || { _netem_log "setup '$name': peer up failed"; netem_teardown "$name"; return 1; }
  ip netns exec "$ns" ip link set lo up 2>/dev/null      || true

  # Shape the host end. Re-tokenize the netem args so callers may pass them as
  # separate words (... delay 50ms) OR as one string (... "delay 50ms"); both
  # must reach tc as distinct tokens. Empty args => bare passthrough netem.
  local _na; _na="$*"
  # shellcheck disable=SC2206  # deliberate word-split of netem tokens (no globs in netem args)
  local -a _netem_args=($_na)
  if ! tc qdisc add dev "$host" root netem "${_netem_args[@]}" 2>/dev/null; then
    _netem_log "setup '$name': tc netem add failed (args: $*)"; netem_teardown "$name"; return 1
  fi
  return 0
}

# netem_change <name> <netem args...>  — live-replace the discipline (phase shifts).
netem_change() {
  local name="$1"; shift || true
  _netem_valid_name "$name" || return 2
  [[ $# -gt 0 ]] || { _netem_log "change '$name': needs netem args"; return 2; }
  local host; host="$(_netem_hostif "$name")"
  local _na; _na="$*"
  # shellcheck disable=SC2206  # deliberate word-split of netem tokens (no globs in netem args)
  local -a _netem_args=($_na)
  if ! tc qdisc replace dev "$host" root netem "${_netem_args[@]}" 2>/dev/null; then
    _netem_log "change '$name': tc netem replace failed (args: $*)"; return 1
  fi
  return 0
}

# netem_teardown <name>  — idempotent; safe to call any number of times.
netem_teardown() {
  local name="$1"
  _netem_valid_name "$name" || return 2
  local ns host; ns="$(_netem_ns "$name")"; host="$(_netem_hostif "$name")"
  tc qdisc del dev "$host" root 2>/dev/null || true   # qdisc (if any)
  ip link del "$host" 2>/dev/null           || true   # removes BOTH veth ends
  ip netns del "$ns" 2>/dev/null            || true   # the namespace
  _netem_untrack "$name"
  return 0
}

# netem_teardown_all  — reap every instance this process created.
netem_teardown_all() {
  local n names=("${_NETEM_INSTANCES[@]:-}")
  for n in "${names[@]}"; do [[ -n "$n" ]] && netem_teardown "$n"; done
  _NETEM_INSTANCES=()
  return 0
}

# --------------------------------------------------------------------------- #
# Selfcheck — proves the shaping path end-to-end and that delay is single-leg. #
# --------------------------------------------------------------------------- #
_netem_ping_avg() { # <ip> -> average RTT in ms on stdout, or non-zero on failure
  local ip="$1" out avg
  out="$(ping -c "$NETEM_PING_COUNT" -i "$NETEM_PING_INTERVAL" -W "$NETEM_PING_TIMEOUT" "$ip" 2>/dev/null)" || return 1
  avg="$(printf '%s\n' "$out" | sed -n 's#.*= [0-9.]*/\([0-9.]*\)/.*#\1#p')"
  [[ -n "$avg" ]] || return 1
  printf '%s' "$avg"
}

netem_selfcheck() {
  netem_require || return $?   # propagates 77 (SKIP-PRIVILEGED) verbatim

  local name="selfcheck" rc=0
  netem_setup "$name" || { _netem_log "selfcheck: setup failed"; return 1; }

  local peer_ip base after delta
  peer_ip="$(_netem_peer_ip "$name")"

  if ! base="$(_netem_ping_avg "$peer_ip")"; then
    _netem_log "selfcheck: baseline ping to $peer_ip failed"; netem_teardown "$name"; return 1
  fi
  if ! netem_change "$name" delay "${NETEM_SELFCHECK_DELAY_MS}ms"; then
    _netem_log "selfcheck: applying delay failed"; netem_teardown "$name"; return 1
  fi
  if ! after="$(_netem_ping_avg "$peer_ip")"; then
    _netem_log "selfcheck: delayed ping to $peer_ip failed"; netem_teardown "$name"; return 1
  fi

  netem_teardown "$name"

  delta="$(awk -v a="$base" -v b="$after" 'BEGIN{printf "%.1f", b-a}')"
  _netem_log "selfcheck: baseline=${base}ms delayed=${after}ms delta=${delta}ms" \
             "(expect [${NETEM_SELFCHECK_MIN_DELTA},${NETEM_SELFCHECK_MAX_DELTA}] for delay ${NETEM_SELFCHECK_DELAY_MS}ms)"

  if awk -v d="$delta" -v lo="$NETEM_SELFCHECK_MIN_DELTA" -v hi="$NETEM_SELFCHECK_MAX_DELTA" \
        'BEGIN{exit !(d>=lo && d<=hi)}'; then
    _netem_log "selfcheck: PASS"; rc=0
  else
    _netem_log "selfcheck: FAIL delta ${delta}ms outside [${NETEM_SELFCHECK_MIN_DELTA},${NETEM_SELFCHECK_MAX_DELTA}]"; rc=1
  fi
  return "$rc"
}

# --------------------------------------------------------------------------- #
# Trap: tear everything down on EXIT / INT / TERM (no qdisc or link ever leaks)#
# --------------------------------------------------------------------------- #
_netem_on_trap() {
  local sig="$1"
  netem_teardown_all
  trap - EXIT INT TERM
  [[ "$sig" != "EXIT" ]] && kill -s "$sig" "$$" 2>/dev/null
  return 0
}
trap '_netem_on_trap EXIT' EXIT
trap '_netem_on_trap INT'  INT
trap '_netem_on_trap TERM' TERM

# --------------------------------------------------------------------------- #
# CLI dispatch (only when executed directly, not when sourced).                #
# --------------------------------------------------------------------------- #
_netem_usage() {
  sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; s/^#//'
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -uo pipefail
  cmd="${1:-selfcheck}"; shift || true
  case "$cmd" in
    selfcheck)        netem_selfcheck; exit $? ;;
    require)          netem_require;   exit $? ;;
    setup)            netem_setup "$@";    exit $? ;;
    change)           netem_change "$@";   exit $? ;;
    teardown)         netem_teardown "$@"; exit $? ;;
    teardown-all|all) netem_teardown_all;  exit $? ;;
    -h|--help|help)   _netem_usage; exit 0 ;;
    *) printf 'netem.sh: unknown command %q (try --help)\n' "$cmd" >&2; exit 2 ;;
  esac
fi

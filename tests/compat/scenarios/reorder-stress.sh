#!/usr/bin/env bash
#
# reorder-stress.sh — SRTLA cross-link packet-reordering stress scenario.
#
# WHY this is THE core SRTLA stress: SRTLA bonds N uplinks of unequal latency
# into one SRT stream. When packet K is striped onto a fast link and packet K+1
# onto a slow one, K+1 can land at the receiver BEFORE later packets that took
# the fast path — the SRT layer at the far end then has to ride out-of-order
# arrival inside its receive-latency window. This scenario manufactures that
# reordering deterministically and proves the bonded stream survives it.
#
# It is dual-use:
#   1. a latency QA gate (default condition must PASS), and
#   2. the measurement instrument for the srt-patch A/B/C evaluation (Task 16):
#      the srt-sink receiver's libsrt and its SRT options are parameterised, so
#      the SAME scenario can be re-run across (A) vanilla libsrt, (B) patched
#      libsrt, (C) vanilla + standard-option equivalents — emitting one
#      machine-parseable summary line per run for the analysis to compare.
#      This script makes NO A/B/C judgement; it only measures.
#
# TOPOLOGY (one veth into a receiver netns; two host source IPs striped across
# per-source egress delay bands — a common receiver reachable over two
# differently-shaped paths, which is exactly what produces cross-link reorder):
#
#       host ns                                   ns-srtla-reorder
#   ffmpeg(SRT caller) -> srtla_send              srtla_rec -> srt-sink
#        (127.0.0.1)        |  src .1 -> [prio 1:1 netem delay 50ms ] \
#                           |                                          >-- veth --> .3
#                           |  src .2 -> [prio 1:2 netem delay 150ms] /
#                           '----------------- veth-reord (egress) ---'
#
#   The peer end lives in a private netns so traffic is FORCED through the veth
#   egress qdisc (two local addresses on one host would short-circuit and skip
#   netem). Per-source delay is done with a classful `prio` qdisc + `u32`
#   filters on source IP feeding two `netem` child disciplines — no policy
#   routing needed because both sources share one /29 to the receiver.
#
# Two reorder mechanisms, both exercised:
#   (i)  asymmetric link delays (50ms vs 150ms) — round-robin striping reorders
#        at the receiver for the whole run.
#   (ii) an explicit `netem reorder 25% 50% delay 20ms` phase layered onto the
#        fast link, so a single link also emits out-of-order packets.
#
# Privilege: needs CAP_NET_ADMIN + ip/tc (veth, netns, tc-netem). Probed via
# netem.sh's netem_require; unprivileged shells SKIP cleanly (exit 77, the
# SKIP-PRIVILEGED code netem_require returns) — falsifiable, never best-effort.
#
# Parameterisation (env vars; empty defaults = today's behaviour, system libsrt):
#   SINK_LD_LIBRARY_PATH  loader path so srt-sink picks a specific libsrt build
#                         (e.g. test-results/libsrt-matrix/install/vanilla/lib).
#   SINK_EXTRA_ARGS       extra srt-sink flags, e.g. "--nakreport 0 --lossmaxttl 30".
#
# Machine-parseable summary line (always emitted on a completed run):
#   reorder-stress: bytes_received=<N> disconnects=<N> duration=<N>s libsrt=<V> ...
#
# Pass criteria (DEFAULT condition): handshake completes, bytes_received >= 5000
# over a >= 30s run, disconnects == 0, and the explicit reorder phase is
# provably active (non-zero packets traversed the reorder-configured qdisc).
#
# Usage:
#   reorder-stress.sh [--build-dir DIR] [--duration SEC] [--keep-logs] [-h]
#     --duration SEC   per-phase length (default 14; total ~= 5 + 2*SEC).
#
# Artifacts land in tests/compat/results/reorder-stress/ (gitignored); nothing
# is written outside the repo and no `../`-escaping path is resolved (Rule D).
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." >/dev/null 2>&1 && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../results/reorder-stress"

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'reorder-stress: %s\n' "$*" >&2; exit 2; }
now_ms() { date +%s%3N; }

# netem.sh: capability gate (netem_require, with its documented exit-77 SKIP
# semantics) + teardown_all safety. We compose our own multi-link-to-one-receiver
# topology with tc directly because netem.sh's one-netns-per-instance model
# cannot express "two shaped links into a single receiver"; sourcing it overrides
# its EXIT trap, so our cleanup calls netem_teardown_all explicitly (its contract).
# shellcheck source=../lib/netem.sh
source "${SCRIPT_DIR}/../lib/netem.sh"

# --------------------------------------------------------------------------- #
# CLI / env                                                                   #
# --------------------------------------------------------------------------- #
BUILD_DIR="${SRTLA_BUILD_DIR:-}"
KEEP_LOGS=0
PHASE_SEC=14
SINK_LD_LIBRARY_PATH="${SINK_LD_LIBRARY_PATH:-}"
SINK_EXTRA_ARGS="${SINK_EXTRA_ARGS:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir) BUILD_DIR="${2:?--build-dir needs a value}"; shift 2 ;;
    --duration)  PHASE_SEC="${2:?--duration needs a value}"; shift 2 ;;
    --keep-logs) KEEP_LOGS=1; shift ;;
    -h|--help)   sed -n '2,52p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown argument '$1' (try --help)" ;;
  esac
done
[[ "$PHASE_SEC" =~ ^[0-9]+$ && "$PHASE_SEC" -ge 1 ]] || die "--duration must be a positive integer"

for tool in ffmpeg jq; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' not found in PATH"
done

# Capability gate — SKIP-PRIVILEGED (exit 77, the code netem_require returns and
# the sibling netem scenarios use) if we cannot shape the network.
if ! netem_require; then
  log "SKIP reorder-stress: netem/veth unavailable (needs root + ip/tc)"
  mkdir -p "$RESULTS_DIR"
  printf '{"scenario":"reorder-stress","skipped":true,"reason":"no CAP_NET_ADMIN / netem"}\n' \
    > "${RESULTS_DIR}/result.json"
  exit 77
fi

resolve_build_dir() {
  local candidates=()
  [[ -n "$BUILD_DIR" ]] && candidates+=("$BUILD_DIR")
  candidates+=("${REPO_ROOT}/build" "/tmp/srtla-build")
  local d
  for d in "${candidates[@]}"; do
    if [[ -x "${d}/srtla_rec" && -x "${d}/srtla_send" \
       && -x "${d}/tests/compat/srt-sink/srt-sink" ]]; then
      printf '%s' "$d"; return 0
    fi
  done
  return 1
}
BUILD_DIR="$(resolve_build_dir)" || die \
  "no usable build dir (need srtla_rec, srtla_send, srt-sink). Build with:
   cmake -B build -DBUILD_COMPAT_TESTS=ON && cmake --build build -j"

SRT_SINK="${BUILD_DIR}/tests/compat/srt-sink/srt-sink"
SRTLA_REC="${BUILD_DIR}/srtla_rec"
SRTLA_SEND="${BUILD_DIR}/srtla_send"

# Absolutise the loader path so it resolves regardless of srt-sink's cwd (the
# caller may pass it relative, e.g. test-results/.../lib).
if [[ -n "$SINK_LD_LIBRARY_PATH" ]]; then
  if [[ -d "$SINK_LD_LIBRARY_PATH" ]]; then
    SINK_LD_LIBRARY_PATH="$(cd -- "$SINK_LD_LIBRARY_PATH" && pwd -P)"
  else
    die "SINK_LD_LIBRARY_PATH '$SINK_LD_LIBRARY_PATH' is not a directory"
  fi
fi

# --------------------------------------------------------------------------- #
# Topology constants                                                          #
# --------------------------------------------------------------------------- #
NS=ns-srtla-reorder
HOSTIF=veth-reord            # <=15 chars (IFNAMSIZ); host (sender) side
PEERIF=npeer-reord          # parked in $NS (receiver side)
SUBNET=10.173.210           # /29 island: .1 + .2 = host sources, .3 = receiver
SRC_A="${SUBNET}.1"         # fast link source
SRC_B="${SUBNET}.2"         # slow link source
RX_IP="${SUBNET}.3"         # srtla_rec listen address
PFX=29

DELAY_A_MS=50               # mechanism (i): asymmetric per-link delay
DELAY_B_MS=150
REORDER_DELAY_MS=20         # mechanism (ii): explicit reorder phase (fast link)

SRTLA_PORT=5401
SINK_PORT=4401
LOCAL_SRT_PORT=6401

# SRT receive window must exceed the worst cross-link skew (150ms + reorder)
# so the bonded stream rides reordering without an end-to-end disconnect; a real
# SRTLA caller (cerastream/Moblin) is tuned the same way. 1.2s >> 150ms+20ms.
SRT_LATENCY_MS=1200
ESTABLISH_SEC=5
MEAS_SEC=$(( ESTABLISH_SEC + 2 * PHASE_SEC ))

rm -rf "$RESULTS_DIR"; mkdir -p "$RESULTS_DIR"
RX_LOG="${RESULTS_DIR}/receiver.log"
TX_LOG="${RESULTS_DIR}/sender.log"
FF_LOG="${RESULTS_DIR}/ffmpeg.log"
SINK_LOG="${RESULTS_DIR}/sink.log"
SINK_JSON="${RESULTS_DIR}/sink.json"
IPS_FILE="${RESULTS_DIR}/ips.txt"
TC_LOG="${RESULTS_DIR}/tc-qdisc.log"
RESULT_JSON="${RESULTS_DIR}/result.json"

# --------------------------------------------------------------------------- #
# Topology + process lifecycle                                                #
# --------------------------------------------------------------------------- #
PIDS=()
track() { PIDS+=("$1"); }

teardown_topology() {
  tc qdisc del dev "$HOSTIF" root 2>/dev/null || true   # qdisc (if link survives the del below)
  ip link del "$HOSTIF" 2>/dev/null || true             # removes BOTH veth ends + child qdiscs
  ip netns del "$NS" 2>/dev/null || true                # the receiver namespace
}

cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill -TERM "$p" 2>/dev/null; done
  teardown_topology
  netem_teardown_all   # no instances created here, but honours netem.sh's trap contract
}
trap cleanup EXIT INT TERM

stop_pid() { local pid="$1"; [[ -n "$pid" ]] || return 0; kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }

wait_for_marker() { # logfile marker timeout_s -> 0 if seen
  local f="$1" m="$2" deadline=$(( $(now_ms) + ${3} * 1000 ))
  while [[ "$(now_ms)" -lt "$deadline" ]]; do
    grep -q -- "$m" "$f" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}

# Packets the child netem qdisc <handle> has Sent (its own counter). Used to
# prove the reorder discipline actually carried traffic during phase (ii).
qdisc_sent_pkts() { # dev handle(e.g. "10:") -> integer
  local n
  n="$(tc -s qdisc show dev "$1" 2>/dev/null | awk -v h="$2" '
        $1=="qdisc" && $3==h {f=1; next}
        f && $1=="Sent" {print $4; exit}')"
  printf '%s' "${n:-0}"
}

setup_topology() {
  ip link set lo up 2>/dev/null || true   # host-side loopback (needed under a fresh netns / unshare)

  ip netns add "$NS"                                   || die "could not create netns '$NS'"
  ip link add "$HOSTIF" type veth peer name "$PEERIF"  || die "could not create veth pair"
  ip link set "$PEERIF" netns "$NS"                    || die "could not move peer into netns"

  ip addr add "${SRC_A}/${PFX}" dev "$HOSTIF"          || die "host addr A failed"
  ip addr add "${SRC_B}/${PFX}" dev "$HOSTIF"          || die "host addr B failed"
  ip link set "$HOSTIF" up                             || die "host link up failed"

  ip netns exec "$NS" ip addr add "${RX_IP}/${PFX}" dev "$PEERIF" || die "peer addr failed"
  ip netns exec "$NS" ip link set "$PEERIF" up         || die "peer link up failed"
  ip netns exec "$NS" ip link set lo up                || true

  # Per-source egress shaping: classful prio + u32(src) -> two netem bands.
  # priomap routes all unclassified IP to band 1:3 (passthrough), so only the
  # two bonded sources are delayed; ARP/control stays fast.
  tc qdisc add dev "$HOSTIF" root handle 1: prio bands 3 \
     priomap 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2                                   || die "prio qdisc failed"
  tc qdisc add dev "$HOSTIF" parent 1:1 handle 10: netem delay "${DELAY_A_MS}ms" || die "netem A failed"
  tc qdisc add dev "$HOSTIF" parent 1:2 handle 20: netem delay "${DELAY_B_MS}ms" || die "netem B failed"
  tc qdisc add dev "$HOSTIF" parent 1:3 handle 30: netem                        || die "netem default failed"
  tc filter add dev "$HOSTIF" parent 1: protocol ip prio 1 u32 \
     match ip src "${SRC_A}/32" flowid 1:1                                     || die "filter A failed"
  tc filter add dev "$HOSTIF" parent 1: protocol ip prio 2 u32 \
     match ip src "${SRC_B}/32" flowid 1:2                                     || die "filter B failed"
}

# --------------------------------------------------------------------------- #
# Run                                                                         #
# --------------------------------------------------------------------------- #
log "==> reorder-stress (build dir: ${BUILD_DIR})"
log "    links: A(${SRC_A}) delay ${DELAY_A_MS}ms | B(${SRC_B}) delay ${DELAY_B_MS}ms -> rx ${RX_IP}:${SRTLA_PORT}"
log "    libsrt loader: ${SINK_LD_LIBRARY_PATH:-<system default>} | sink extra args: ${SINK_EXTRA_ARGS:-<none>}"

teardown_topology       # clean slate (idempotent)
setup_topology

# srt-sink (in the receiver netns) — parameterised libsrt + extra SRT flags.
# Run in the MAIN shell (never $(...)) so teardown's wait can block on its JSON
# flush. ldd-resolve the chosen libsrt first so the swap is provable in the log.
SINK_RESOLVED="$(LD_LIBRARY_PATH="$SINK_LD_LIBRARY_PATH" ldd "$SRT_SINK" 2>/dev/null | awk '/libsrt/{print $3; exit}')"
log "    srt-sink libsrt resolves to: ${SINK_RESOLVED:-<system default>}"
# shellcheck disable=SC2206  # deliberate word-split of caller-supplied sink flags
SINK_ARGS=($SINK_EXTRA_ARGS)
ip netns exec "$NS" env LD_LIBRARY_PATH="$SINK_LD_LIBRARY_PATH" \
   "$SRT_SINK" --port "$SINK_PORT" --host 127.0.0.1 --result "$SINK_JSON" \
               --latency "$SRT_LATENCY_MS" --duration $(( MEAS_SEC + 25 )) \
               "${SINK_ARGS[@]}" >"$SINK_LOG" 2>&1 &
SINK_PID=$!; track "$SINK_PID"
sleep 0.5

# srtla_rec (in the receiver netns) forwards the bonded SRTLA stream to srt-sink.
ip netns exec "$NS" "$SRTLA_REC" --srtla_port "$SRTLA_PORT" --srt_hostname 127.0.0.1 \
   --srt_port "$SINK_PORT" --log_level trace >"$RX_LOG" 2>&1 &
RX_PID=$!; track "$RX_PID"
wait_for_marker "$RX_LOG" "srtla_rec is now running" 5 || die "receiver never came up"

# srtla_send (host) bonds the two source IPs toward the receiver.
# RUST_LOG only affects the Rust fork sender (the C sender logs unconditionally);
# without it the fork is silent and the both-links-added evidence grep sees nothing.
printf '%s\n%s\n' "$SRC_A" "$SRC_B" > "$IPS_FILE"
RUST_LOG="${RUST_LOG:-info}" "$SRTLA_SEND" "$LOCAL_SRT_PORT" "$RX_IP" "$SRTLA_PORT" "$IPS_FILE" >"$TX_LOG" 2>&1 &
TX_PID=$!; track "$TX_PID"
sleep 0.6

# SRT media caller. Deep send buffer + generous I/O timeout so the bonded stream
# rides cross-link reorder without libsrt tearing the muxer down (ffmpeg SRT
# latency/timeout options are in MICROSECONDS).
SRT_LATENCY_US=$(( SRT_LATENCY_MS * 1000 ))
SRT_OPTS="mode=caller&transtype=live&latency=${SRT_LATENCY_US}&peerlatency=${SRT_LATENCY_US}&sndbuf=24000000&timeout=30000000"
ffmpeg -hide_banner -loglevel warning -re \
  -f lavfi -i testsrc2=size=320x240:rate=25 -c:v mpeg2video -b:v 700k -f mpegts \
  "srt://127.0.0.1:${LOCAL_SRT_PORT}?${SRT_OPTS}" \
  >"$FF_LOG" 2>&1 &
FF_PID=$!; track "$FF_PID"

handshake=false
wait_for_marker "$RX_LOG" "Group registered" 10 && handshake=true

both_links_added=false
if grep -q -- "$SRC_A" "$TX_LOG" 2>/dev/null && grep -q -- "$SRC_B" "$TX_LOG" 2>/dev/null; then
  both_links_added=true
fi

# ----------------------------------------------------------------------------- #
# Phase i — asymmetric link delays carry the stream (natural cross-link reorder).#
# ----------------------------------------------------------------------------- #
log "==> phase i: asymmetric delays ${DELAY_A_MS}ms / ${DELAY_B_MS}ms for ${PHASE_SEC}s"
sleep "$ESTABLISH_SEC"
sleep "$PHASE_SEC"

# ----------------------------------------------------------------------------- #
# Phase ii — layer an explicit reorder discipline onto the fast link.            #
# ----------------------------------------------------------------------------- #
log "==> phase ii: netem reorder 25% 50% delay ${REORDER_DELAY_MS}ms on link A for ${PHASE_SEC}s"
tc qdisc change dev "$HOSTIF" parent 1:1 handle 10: \
   netem delay "${REORDER_DELAY_MS}ms" reorder 25% 50% \
   || die "could not apply reorder discipline"

reorder_configured=false
{ printf '=== after applying reorder (phase ii start) ===\n'; tc -s qdisc show dev "$HOSTIF"; } >>"$TC_LOG" 2>&1
tc qdisc show dev "$HOSTIF" 2>/dev/null | grep -q 'reorder' && reorder_configured=true

reorder_p0="$(qdisc_sent_pkts "$HOSTIF" "10:")"   # fast-link pkts before phase ii traffic
sleep "$PHASE_SEC"
reorder_p1="$(qdisc_sent_pkts "$HOSTIF" "10:")"   # ... after
band_b_pkts="$(qdisc_sent_pkts "$HOSTIF" "20:")"  # slow-link total (asymmetry proof)
{ printf '=== after phase ii (phase ii end) ===\n'; tc -s qdisc show dev "$HOSTIF"; } >>"$TC_LOG" 2>&1

[[ "$reorder_p0" =~ ^[0-9]+$ ]] || reorder_p0=0
[[ "$reorder_p1" =~ ^[0-9]+$ ]] || reorder_p1=0
[[ "$band_b_pkts" =~ ^[0-9]+$ ]] || band_b_pkts=0
reorder_pkts=$(( reorder_p1 - reorder_p0 ))
[[ "$reorder_pkts" -lt 0 ]] && reorder_pkts=0

# ----------------------------------------------------------------------------- #
# Teardown — SINK FIRST so the intentional ffmpeg/sender stop is not miscounted  #
# as a mid-stream disconnect.                                                    #
# ----------------------------------------------------------------------------- #
stop_pid "$SINK_PID"
[[ -n "${FF_PID:-}" ]] && { kill -TERM "$FF_PID" 2>/dev/null; wait "$FF_PID" 2>/dev/null; }
stop_pid "$TX_PID"
stop_pid "$RX_PID"

# --------------------------------------------------------------------------- #
# Metrics                                                                     #
# --------------------------------------------------------------------------- #
bytes="$(jq -r '.bytes_received // 0' "$SINK_JSON" 2>/dev/null || echo 0)"
disc="$(jq -r '.disconnects // -1'    "$SINK_JSON" 2>/dev/null || echo -1)"
sdur_ms="$(jq -r '.duration_ms // 0'  "$SINK_JSON" 2>/dev/null || echo 0)"
[[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
[[ "$disc" =~ ^-?[0-9]+$ ]] || disc=-1
[[ "$sdur_ms" =~ ^[0-9]+$ ]] || sdur_ms=0
duration_s=$(( sdur_ms / 1000 ))

# libsrt version straight from the Task-4 srt-sink banner (proves which build ran).
libsrt_ver="$(sed -n 's/^srt-sink: libsrt version \([0-9.]*\).*/\1/p' "$SINK_LOG" 2>/dev/null | head -1)"
[[ -n "$libsrt_ver" ]] || libsrt_ver="unknown"

# --------------------------------------------------------------------------- #
# Verdict (DEFAULT condition). A/B/C analysis is NOT decided here (Task 16).   #
# --------------------------------------------------------------------------- #
handshake_ok=$handshake
bytes_ok=false;          [[ "$bytes" -ge 5000 ]] && bytes_ok=true
disc_ok=false;           [[ "$disc" -eq 0 ]] && disc_ok=true
duration_ok=false;       [[ "$duration_s" -ge 30 ]] && duration_ok=true
reorder_active=false;    [[ "$reorder_configured" == true && "$reorder_pkts" -gt 0 ]] && reorder_active=true

pass=false
[[ "$handshake_ok" == true && "$bytes_ok" == true && "$disc_ok" == true \
   && "$duration_ok" == true && "$reorder_active" == true ]] && pass=true

jq -n \
  --argjson pass "$pass" \
  --argjson handshake_ok "$handshake_ok" --argjson both_links_added "$both_links_added" \
  --argjson bytes_ok "$bytes_ok" --argjson disc_ok "$disc_ok" \
  --argjson duration_ok "$duration_ok" --argjson reorder_active "$reorder_active" \
  --argjson reorder_configured "$reorder_configured" \
  --argjson bytes "$bytes" --argjson disconnects "$disc" \
  --argjson duration_s "$duration_s" \
  --argjson reorder_pkts "$reorder_pkts" --argjson band_b_pkts "$band_b_pkts" \
  --arg libsrt "$libsrt_ver" \
  --arg sink_libsrt_path "${SINK_RESOLVED:-system}" \
  --arg sink_extra_args "${SINK_EXTRA_ARGS:-}" \
  --argjson delay_a_ms "$DELAY_A_MS" --argjson delay_b_ms "$DELAY_B_MS" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    scenario:"reorder-stress", pass:$pass,
    criteria:{handshake_ok:$handshake_ok, bytes_ok:$bytes_ok,
              disconnects_ok:$disc_ok, duration_ok:$duration_ok,
              reorder_active:$reorder_active},
    establish:{handshake:$handshake_ok, both_links_added:$both_links_added},
    sink:{bytes_received:$bytes, disconnects:$disconnects, duration_s:$duration_s,
          libsrt_version:$libsrt, libsrt_path:$sink_libsrt_path,
          extra_args:$sink_extra_args},
    reorder:{configured:$reorder_configured, phase_ii_pkts:$reorder_pkts,
             fast_delay_ms:$delay_a_ms, slow_delay_ms:$delay_b_ms,
             slow_link_pkts:$band_b_pkts},
    timestamp:$ts
  }' > "$RESULT_JSON"

# Machine-parseable summary line (the required metrics come FIRST and adjacent
# so `grep -E 'bytes_received=[0-9]+ disconnects=0'` matches on a PASS run).
log ""
log "reorder-stress: bytes_received=${bytes} disconnects=${disc} duration=${duration_s}s libsrt=${libsrt_ver} reorder_pkts=${reorder_pkts} slow_link_pkts=${band_b_pkts}"
log ""
log "================ reorder-stress summary ================"
log "  handshake_ok=${handshake_ok} (both_links_added=${both_links_added})"
log "  bytes_ok=${bytes_ok} (bytes=${bytes} >= 5000) disc_ok=${disc_ok} (disc=${disc})"
log "  duration_ok=${duration_ok} (duration=${duration_s}s >= 30)"
log "  reorder_active=${reorder_active} (configured=${reorder_configured} phase_ii_pkts=${reorder_pkts})"
log "  libsrt=${libsrt_ver} loader=${SINK_RESOLVED:-<system default>}"
log "  result: ${RESULT_JSON}"
log "======================================================="

if [[ "$KEEP_LOGS" -eq 0 && "$pass" == true ]]; then
  rm -f "$RX_LOG" "$TX_LOG" "$FF_LOG" "$SINK_LOG" "$IPS_FILE" "$TC_LOG"
fi

if [[ "$pass" == true ]]; then log "PASS"; exit 0; else log "FAIL"; exit 1; fi

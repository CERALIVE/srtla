#!/usr/bin/env bash
#
# jitter-stress.sh — SRTLA quality-evaluation-under-jitter scenario (2 bonded links).
#
# Stresses the receiver's RTT-variance quality path (RTT_VARIANCE_THRESHOLD=50ms,
# src/receiver_config.h:50) with pure delay jitter and ZERO packet loss. The
# headline contract under test: jitter alone — even severe, normally-distributed
# jitter several times the variance threshold — must NEVER reap a healthy link or
# drop the bonded stream. The evaluator may *down-weight* a jittery link, but it
# must not remove it: reaping is timeout-driven (CONN_TIMEOUT/GROUP_TIMEOUT), and
# a link that keeps delivering packets (just late) is never idle.
#
# Three sequential 30 s phases, increasing jitter, applied LIVE to the running
# qdisc via netem_change — the SAME sender/receiver/sink processes survive all
# three phases (no restart, constant PIDs):
#
#   Phase 1:  delay 150ms  50ms                      (jitter == variance threshold)
#   Phase 2:  delay 150ms 100ms                      (2x threshold)
#   Phase 3:  delay 150ms 200ms distribution normal  (4x threshold, gaussian)
#
# Topology — single-leg-shaped veth into a private netns (NOT loopback: netem on
# `lo` shapes both legs and doubles the RTT, corrupting every latency assertion;
# see tests/compat/lib/netem.sh). The receiver + sink live in the netns; the
# sender drives TWO bonded source IPs that BOTH egress the one shaped host veth,
# so a single netem_change retunes the jitter seen by BOTH links at once:
#
#       host ns                              ns-srtla-<NAME>
#   .------------------------.   veth pair   .----------------------.
#   | srtla_send (host)      |               | srtla_rec  (in netns)|
#   |   src .173.N.1  --------|---[ netem ]---|--> .173.N.2 :SRTLA   |
#   |   src .174.N.1  --------|---[ jitter]---|--> (same dst, 2nd IP)|
#   | ffmpeg -> :LOCAL_SRT    |               |   -> srt-sink :SINK  |
#   '------------------------'    ^ shaped    '----------------------'
#                                   host-end egress only (single-leg)
#
#   ffmpeg(SRT caller) -> srtla_send =[2 jittered links]=> srtla_rec -> srt-sink
#
# WHY disconnects ARE a gate here (unlike link-drop.sh):
#   link-drop.sh hard-kills a link mid-stream and does NOT gate on end-to-end SRT
#   `disconnects` — riding a dual-direction link kill without an SRT break is an
#   app-layer caller property orthogonal to bonding correctness. This scenario
#   kills NOTHING: every packet is delivered, only late. A jitter-only run that
#   the SRT recv window (multi-second) cannot absorb would be a real defect, so
#   `disconnects == 0` IS asserted here (same stance as sighup-reload.sh, which
#   also tears down no link).
#
# PASS <=> both links establish AND each 30 s phase streams >= MIN_PHASE_BYTES
#          with strictly-increasing throughput AND the receiver reaps ZERO links
#          AND the sender never false-fails a link AND disconnects == 0.
#
# Needs CAP_NET_ADMIN + ip/tc/ping (netem_require). Without it the scenario SKIPs
# cleanly (exit 77, SKIP-PRIVILEGED) rather than silently passing.
#
# Usage:
#   jitter-stress.sh [--build-dir DIR] [--keep-logs] [-h]
#
# Artifacts land in tests/compat/results/jitter-stress/ (gitignored); nothing is
# written outside the repo (Rule D).
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." >/dev/null 2>&1 && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"
RESULTS_DIR="${SCRIPT_DIR}/../results/jitter-stress"

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'jitter-stress: %s\n' "$*" >&2; exit 2; }
now_ms() { date +%s%3N; }

BUILD_DIR="${SRTLA_BUILD_DIR:-}"
KEEP_LOGS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir) BUILD_DIR="${2:?--build-dir needs a value}"; shift 2 ;;
    --keep-logs) KEEP_LOGS=1; shift ;;
    -h|--help)   sed -n '2,55p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown argument '$1' (try --help)" ;;
  esac
done

for tool in ffmpeg jq; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' not found in PATH"
done

# Source the netem shaping library (arms its own teardown trap; ours overrides
# below and therefore MUST call netem_teardown_all from its cleanup handler).
# shellcheck source=../lib/netem.sh
source "${LIB_DIR}/netem.sh" || die "could not source ${LIB_DIR}/netem.sh"

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

# Capability gate FIRST — clean SKIP (exit 77) when unprivileged, leaving no
# state behind (mirrors netem_require / pcap-replay exit-77 SKIP semantics).
mkdir -p "$RESULTS_DIR"
if ! netem_require; then
  log "SKIP jitter-stress: netem unavailable (needs CAP_NET_ADMIN + ip/tc/ping)"
  printf '{"scenario":"jitter-stress","skipped":true,"reason":"netem unavailable (need root + ip/tc/ping)"}\n' \
    > "${RESULTS_DIR}/result.json"
  exit 77
fi

# --------------------------------------------------------------------------- #
# Parameters                                                                   #
# --------------------------------------------------------------------------- #
NAME=jitstress
PHASE_SEC=30
MIN_PHASE_BYTES=5000      # each 30 s phase must move at least this much media

# Jitter disciplines per phase (exact tc-netem args; NO loss/reorder — this
# scenario isolates the jitter variable). 150 ms base RTT, jitter 1x/2x/4x the
# 50 ms RTT_VARIANCE_THRESHOLD; phase 3 switches to a normal distribution.
PHASE1_NETEM="delay 150ms 50ms"
PHASE2_NETEM="delay 150ms 100ms"
PHASE3_NETEM="delay 150ms 200ms distribution normal"

SRTLA_PORT=5701
SINK_PORT=4701
LOCAL_SRT_PORT=6701

# The SRT recv window must dwarf the worst-case jitter so the bonded stream rides
# through it with no end-to-end break: phase-3 gaussian jitter peaks well under a
# second, 4000 ms absorbs it with margin (a production caller is tuned the same).
SRT_LATENCY_MS=4000
SRT_LATENCY_US=$(( SRT_LATENCY_MS * 1000 ))

RX_LOG="${RESULTS_DIR}/receiver.log"
TX_LOG="${RESULTS_DIR}/sender.log"
FF_LOG="${RESULTS_DIR}/ffmpeg.log"
FF_PROGRESS="${RESULTS_DIR}/ffmpeg.progress"
SINK_JSON="${RESULTS_DIR}/sink.json"
STATS_FILE="${RESULTS_DIR}/sender-stats.json"
IPS_FILE="${RESULTS_DIR}/ips.txt"
RESULT_JSON="${RESULTS_DIR}/result.json"

rm -f "$RX_LOG" "$TX_LOG" "$FF_LOG" "$FF_PROGRESS" "$SINK_JSON" \
      "$STATS_FILE" "$IPS_FILE" "$RESULT_JSON" "${SINK_JSON%.json}.log"

PIDS=()
track() { PIDS+=("$1"); }

# Our cleanup OVERRIDES netem.sh's trap, so it must reap the netem instances too.
cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill -TERM "$p" 2>/dev/null; done
  netem_teardown_all
}
trap cleanup EXIT INT TERM

stop_pid() { local pid="$1"; [[ -n "$pid" ]] || return 0; kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }

wait_for_marker() { # logfile marker timeout_s -> 0 if seen
  local f="$1" m="$2" deadline=$(( $(now_ms) + ${3} * 1000 ))
  while [[ "$(now_ms)" -lt "$deadline" ]]; do
    grep -qE -- "$m" "$f" 2>/dev/null && return 0
    sleep 0.2
  done
  return 1
}

# grep -c always prints one integer; capture it so a no-match exit 1 does not
# append a stray line that would corrupt numeric comparisons.
count_re() { local n; n=$(grep -Ec -- "$2" "$1" 2>/dev/null); printf '%s' "${n:-0}"; }

# Cumulative bytes pushed through the (lossless) pipeline, read live from ffmpeg
# -progress. With delay/jitter only (no drops) this tracks received bytes within
# one SRT window — the per-phase, constant-process throughput probe the sink
# cannot give us (it writes its byte total only at exit).
ff_total_size() {
  local v
  v=$(grep -a '^total_size=' "$FF_PROGRESS" 2>/dev/null | tail -1 | cut -d= -f2)
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v" || printf '0'
}

# Max link count the sender telemetry reports over a few samples in this phase
# (proves BOTH links stay registered without scraping the log).
telemetry_max_conns() {
  local best=0 n _
  for _ in 1 2 3; do
    n=$(jq -r '.connections | length' "$STATS_FILE" 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] && (( n > best )) && best="$n"
    sleep 0.3
  done
  printf '%s' "$best"
}

# --------------------------------------------------------------------------- #
# Shape link 1 with phase-1 jitter and derive the topology. The library owns a  #
# stable /30 derivation (host .1 / peer .2 on 10.173.<octet>.0/30); we read it   #
# through its helpers and add a SECOND /30 (10.174.<octet>.0/30) on the same     #
# veth+peer so a single shaped iface carries two bonded source IPs to one recv.  #
# --------------------------------------------------------------------------- #
log "==> setup: shape link with '${PHASE1_NETEM}' (build dir: ${BUILD_DIR})"
netem_setup "$NAME" $PHASE1_NETEM || die "netem_setup failed"

NS="$(_netem_ns "$NAME")"
HOST_IF="$(_netem_hostif "$NAME")"
PEER_IF="$(_netem_peerif "$NAME")"
OCTET="$(_netem_octet "$NAME")"

LINK1_SRC="$(_netem_host_ip "$NAME")"          # 10.173.<octet>.1 (host veth)
RECV_IP="$(_netem_peer_ip "$NAME")"            # 10.173.<octet>.2 (netns, dst)
LINK2_SRC="10.174.${OCTET}.1"                  # 2nd host source IP (same veth)
LINK2_PEER="10.174.${OCTET}.2"                 # 2nd peer addr (same npeer)

# Second address pair on the existing (already-up, already-shaped) ifaces.
ip addr add "${LINK2_SRC}/30" dev "$HOST_IF" 2>/dev/null \
  || die "could not add 2nd host source IP ${LINK2_SRC} on ${HOST_IF}"
ip netns exec "$NS" ip addr add "${LINK2_PEER}/30" dev "$PEER_IF" 2>/dev/null \
  || die "could not add 2nd peer IP ${LINK2_PEER} in ${NS}"

log "    links: ${LINK1_SRC} + ${LINK2_SRC}  ->  ${RECV_IP}:${SRTLA_PORT} (netns ${NS})"

# --------------------------------------------------------------------------- #
# Bring up the pipeline: sink + receiver inside the netns, sender + ffmpeg on    #
# the host. srt-sink/receiver run via `ip netns exec` (same PID after exec, so   #
# kill/wait at teardown still flush their results).                              #
# --------------------------------------------------------------------------- #
ip netns exec "$NS" "$SRT_SINK" --port "$SINK_PORT" --host 127.0.0.1 \
    --result "$SINK_JSON" --latency "$SRT_LATENCY_MS" \
    --duration $(( PHASE_SEC * 3 + 40 )) >"${SINK_JSON%.json}.log" 2>&1 &
SINK_PID=$!; track "$SINK_PID"
sleep 0.5

ip netns exec "$NS" "$SRTLA_REC" --srtla_port "$SRTLA_PORT" \
    --srt_hostname 127.0.0.1 --srt_port "$SINK_PORT" --log_level trace \
    >"$RX_LOG" 2>&1 &
RX_PID=$!; track "$RX_PID"
wait_for_marker "$RX_LOG" "srtla_rec is now running" 5 || die "receiver never came up"

printf '%s\n%s\n' "$LINK1_SRC" "$LINK2_SRC" > "$IPS_FILE"
"$SRTLA_SEND" "$LOCAL_SRT_PORT" "$RECV_IP" "$SRTLA_PORT" "$IPS_FILE" \
    --stats-file "$STATS_FILE" >"$TX_LOG" 2>&1 &
TX_PID=$!; track "$TX_PID"
sleep 0.6

SRT_OPTS="mode=caller&transtype=live&latency=${SRT_LATENCY_US}&peerlatency=${SRT_LATENCY_US}&sndbuf=24000000&timeout=30000000"
ffmpeg -hide_banner -loglevel warning -progress "$FF_PROGRESS" -re \
  -f lavfi -i testsrc2=size=320x240:rate=25 -c:v mpeg2video -b:v 700k -f mpegts \
  "srt://127.0.0.1:${LOCAL_SRT_PORT}?${SRT_OPTS}" >"$FF_LOG" 2>&1 &
FF_PID=$!; track "$FF_PID"

handshake=false
wait_for_marker "$RX_LOG" "Group registered" 10 && handshake=true

# Both bonded source IPs must be added by the sender.
both_links_added=false
if grep -q -- "$LINK1_SRC" "$TX_LOG" 2>/dev/null \
   && grep -q -- "$LINK2_SRC" "$TX_LOG" 2>/dev/null; then
  both_links_added=true
fi
log "    handshake=${handshake} both_links_added=${both_links_added} (tx_pid=${TX_PID} rx_pid=${RX_PID})"

# Baselines snapshotted BEFORE the stress window: only NEW reaps / link-fails
# during the phases count against us.
reaps_conn_pre=$(count_re "$RX_LOG" "conn_removed")
reaps_group_pre=$(count_re "$RX_LOG" "group_reaped")
linkfail_pre=$(count_re "$TX_LOG" "connection failed, attempting to reconnect")

# --------------------------------------------------------------------------- #
# Run the three jitter phases on the SAME processes; sample per-phase progress,  #
# telemetry link count, and process liveness at each boundary.                  #
# --------------------------------------------------------------------------- #
run_phase() { # phase_no netem_args... -> echoes "<total_size> <max_conns> <alive>"
  local no="$1"; shift
  local args="$*"
  if [[ "$no" -gt 1 ]]; then
    netem_change "$NAME" $args || die "netem_change (phase ${no}) failed"
  fi
  log "==> phase ${no}: netem '${args}'  (tx_pid=${TX_PID} rx_pid=${RX_PID})"
  sleep "$PHASE_SEC"
  local size conns alive=ok
  size="$(ff_total_size)"
  conns="$(telemetry_max_conns)"
  kill -0 "$TX_PID" 2>/dev/null || alive=tx_dead
  kill -0 "$RX_PID" 2>/dev/null || alive=rx_dead
  log "    phase ${no}: total_size=${size} telemetry_conns=${conns} pids_alive=${alive}"
  printf '%s %s %s' "$size" "$conns" "$alive"
}

read -r B1 CONNS1 ALIVE1 < <(run_phase 1 $PHASE1_NETEM)
read -r B2 CONNS2 ALIVE2 < <(run_phase 2 $PHASE2_NETEM)
read -r B3 CONNS3 ALIVE3 < <(run_phase 3 $PHASE3_NETEM)

# Snapshot reaps / link-fails at the end of the stress window, BEFORE teardown
# (an intentional teardown later would idle-reap the group — not what we test).
reaps_conn_post=$(count_re "$RX_LOG" "conn_removed")
reaps_group_post=$(count_re "$RX_LOG" "group_reaped")
linkfail_post=$(count_re "$TX_LOG" "connection failed, attempting to reconnect")

# --------------------------------------------------------------------------- #
# Teardown — SINK FIRST so the intentional sender/ffmpeg stop is never counted   #
# as a mid-stream disconnect, then sender, then receiver, then netem.            #
# --------------------------------------------------------------------------- #
stop_pid "$SINK_PID"
[[ -n "${FF_PID:-}" ]] && { kill -TERM "$FF_PID" 2>/dev/null; wait "$FF_PID" 2>/dev/null; }
stop_pid "$TX_PID"
stop_pid "$RX_PID"
netem_teardown "$NAME"

bytes="$(jq -r '.bytes_received // 0' "$SINK_JSON" 2>/dev/null || echo 0)"
disc="$(jq -r '.disconnects // -1'   "$SINK_JSON" 2>/dev/null || echo -1)"
[[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
[[ "$disc" =~ ^-?[0-9]+$ ]] || disc=-1

# Post-run shaping-residue check: the host veth must be gone (exact, since only
# the host end is visible to `ip link show`).
shaping_residue=$(ip link show 2>/dev/null | grep -c "veth-srtla" || true)
[[ "$shaping_residue" =~ ^[0-9]+$ ]] || shaping_residue=0

# --------------------------------------------------------------------------- #
# Criteria.                                                                     #
# --------------------------------------------------------------------------- #
establish_ok=false
[[ "$handshake" == true && "$both_links_added" == true ]] && establish_ok=true

# Per-phase throughput: each phase moved >= MIN_PHASE_BYTES and throughput is
# strictly increasing (0 < B1 < B2 < B3, each delta over the threshold).
d1="$B1"; d2=$(( B2 - B1 )); d3=$(( B3 - B2 ))
phase_bytes_ok=false
if [[ "$B1" =~ ^[0-9]+$ && "$B2" =~ ^[0-9]+$ && "$B3" =~ ^[0-9]+$ \
   && "$d1" -ge "$MIN_PHASE_BYTES" && "$d2" -ge "$MIN_PHASE_BYTES" \
   && "$d3" -ge "$MIN_PHASE_BYTES" && "$B1" -lt "$B2" && "$B2" -lt "$B3" ]]; then
  phase_bytes_ok=true
fi

# The headline assertion: jitter reaped NOTHING on the receiver.
no_reaps_ok=false
[[ "$reaps_conn_post" -le "$reaps_conn_pre" && "$reaps_group_post" -le "$reaps_group_pre" ]] \
  && no_reaps_ok=true

# Sender kept both links: no NEW false link-down, and telemetry showed 2 links
# registered in every phase.
links_registered_ok=false
if [[ "$linkfail_post" -le "$linkfail_pre" \
   && "$CONNS1" -ge 2 && "$CONNS2" -ge 2 && "$CONNS3" -ge 2 ]]; then
  links_registered_ok=true
fi

# Processes survived every phase (constant PIDs — never restarted).
pids_constant_ok=false
[[ "$ALIVE1" == ok && "$ALIVE2" == ok && "$ALIVE3" == ok ]] && pids_constant_ok=true

# Jitter-only IS gated on disconnects (see header): nothing was killed, so the
# multi-second SRT window must have ridden every phase with no end-to-end break.
disconnects_ok=false
[[ "$disc" -eq 0 ]] && disconnects_ok=true

stream_total_ok=false
[[ "$bytes" -ge $(( MIN_PHASE_BYTES * 3 )) ]] && stream_total_ok=true

residue_ok=false
[[ "$shaping_residue" -eq 0 ]] && residue_ok=true

pass=false
[[ "$establish_ok" == true && "$phase_bytes_ok" == true && "$no_reaps_ok" == true \
   && "$links_registered_ok" == true && "$pids_constant_ok" == true \
   && "$disconnects_ok" == true && "$stream_total_ok" == true \
   && "$residue_ok" == true ]] && pass=true

jq -n \
  --argjson pass "$pass" \
  --argjson establish_ok "$establish_ok" \
  --argjson phase_bytes_ok "$phase_bytes_ok" \
  --argjson no_reaps_ok "$no_reaps_ok" \
  --argjson links_registered_ok "$links_registered_ok" \
  --argjson pids_constant_ok "$pids_constant_ok" \
  --argjson disconnects_ok "$disconnects_ok" \
  --argjson stream_total_ok "$stream_total_ok" \
  --argjson residue_ok "$residue_ok" \
  --argjson handshake "$handshake" \
  --argjson both_links_added "$both_links_added" \
  --argjson b1 "$B1" --argjson b2 "$B2" --argjson b3 "$B3" \
  --argjson d1 "$d1" --argjson d2 "$d2" --argjson d3 "$d3" \
  --argjson min_phase_bytes "$MIN_PHASE_BYTES" \
  --argjson conns1 "$CONNS1" --argjson conns2 "$CONNS2" --argjson conns3 "$CONNS3" \
  --argjson reaps_conn "$(( reaps_conn_post - reaps_conn_pre ))" \
  --argjson reaps_group "$(( reaps_group_post - reaps_group_pre ))" \
  --argjson linkfails "$(( linkfail_post - linkfail_pre ))" \
  --argjson bytes "$bytes" \
  --argjson disconnects "$disc" \
  --argjson shaping_residue "$shaping_residue" \
  --argjson tx_pid "$TX_PID" --argjson rx_pid "$RX_PID" \
  --arg phase1 "$PHASE1_NETEM" --arg phase2 "$PHASE2_NETEM" --arg phase3 "$PHASE3_NETEM" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    scenario:"jitter-stress", pass:$pass,
    criteria:{establish_ok:$establish_ok, phase_bytes_ok:$phase_bytes_ok,
              no_reaps_ok:$no_reaps_ok, links_registered_ok:$links_registered_ok,
              pids_constant_ok:$pids_constant_ok, disconnects_ok:$disconnects_ok,
              stream_total_ok:$stream_total_ok, residue_ok:$residue_ok},
    establish:{handshake:$handshake, both_links_added:$both_links_added,
               tx_pid:$tx_pid, rx_pid:$rx_pid},
    phases:[{netem:$phase1, total_size:$b1, delta:$d1, telemetry_conns:$conns1},
            {netem:$phase2, total_size:$b2, delta:$d2, telemetry_conns:$conns2},
            {netem:$phase3, total_size:$b3, delta:$d3, telemetry_conns:$conns3}],
    min_phase_bytes:$min_phase_bytes,
    reaps:{conn_removed:$reaps_conn, group_reaped:$reaps_group},
    sender:{new_link_failures:$linkfails},
    stream:{bytes_received:$bytes, disconnects:$disconnects},
    shaping_residue:$shaping_residue,
    timestamp:$ts
  }' > "$RESULT_JSON"

log ""
log "================ jitter-stress summary ================"
log "  establish_ok=${establish_ok} (handshake=${handshake} both_links=${both_links_added})"
log "  phase_bytes_ok=${phase_bytes_ok} (b1=${B1} b2=${B2} b3=${B3}; deltas ${d1}/${d2}/${d3} >= ${MIN_PHASE_BYTES})"
log "  no_reaps_ok=${no_reaps_ok} (conn_removed=$(( reaps_conn_post - reaps_conn_pre )) group_reaped=$(( reaps_group_post - reaps_group_pre )))"
log "  links_registered_ok=${links_registered_ok} (telemetry conns ${CONNS1}/${CONNS2}/${CONNS3}; new link-fails=$(( linkfail_post - linkfail_pre )))"
log "  pids_constant_ok=${pids_constant_ok} (tx=${TX_PID} rx=${RX_PID}; alive ${ALIVE1}/${ALIVE2}/${ALIVE3})"
log "  disconnects_ok=${disconnects_ok} (disc=${disc}) [GATED — jitter killed no link]"
log "  stream_total_ok=${stream_total_ok} (bytes_received=${bytes})"
log "  residue_ok=${residue_ok} (veth-srtla count=${shaping_residue})"
log "  result: ${RESULT_JSON}"
log "======================================================="

if [[ "$KEEP_LOGS" -eq 0 && "$pass" == true ]]; then
  rm -f "$RX_LOG" "$TX_LOG" "$FF_LOG" "$FF_PROGRESS" "${SINK_JSON%.json}.log" \
        "$STATS_FILE" "$IPS_FILE"
fi

if [[ "$pass" == true ]]; then log "PASS"; exit 0; else log "FAIL"; exit 1; fi

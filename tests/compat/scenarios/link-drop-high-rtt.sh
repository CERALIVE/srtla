#!/usr/bin/env bash
#
# link-drop-high-rtt.sh — bonded link-drop / shift scenario under high RTT.
#
# Combines the netem veth/netns shaping library (tests/compat/lib/netem.sh,
# Task 3) with the link-drop isolation pattern (scenarios/link-drop.sh): two
# bonded srtla_send source IPs ride a single tc-netem-shaped veth into a private
# network namespace that hosts srtla_rec + srt-sink, then one link is killed
# mid-stream with iptables. Proves the sender still shifts off a dead uplink and
# the survivor keeps delivering media when every packet crosses a 200ms one-way
# delay with realistic jitter.
#
# EXACT SHAPING PARAMETERS — applied to BOTH links (they share the shaped host
# veth egress qdisc, exactly the way link-drop's two loopback IPs share `lo`):
#
#     tc qdisc ... root netem delay 200ms 20ms distribution normal
#
# netem.sh shapes ONE leg only (host -> netns egress, which is the sender->
# receiver DATA path), so the RTT delta ~= the configured one-way delay: a real
# ~200ms RTT, not the 2x artifact `netem` on loopback would inject. See the WHY
# block at the top of tests/compat/lib/netem.sh.
#
# TOPOLOGY:
#                       host netns                       ns-srtla-hrtt
#  ffmpeg(SRT caller) -> srtla_send                 .------------------------.
#     127.0.0.1:LOCAL    |  src 172.31.77.1 (link1) |  srtla_rec @ .254:PORT  |
#                        |  src 172.31.77.2 (link2) |     -> srt-sink @ lo    |
#                        '---[ veth-srtla-hrtt ]----|--[ npeer-hrtt .254 ]----'
#                              ^ netem 200ms 20ms (host egress = the data path)
#  Both source IPs sit on the shaped host veth, so BOTH bonded links carry the
#  200ms RTT — analogous to link-drop putting 127.0.0.1/127.0.0.2 both on `lo`.
#
# PHASES:
#   1. establish — both source IPs register through the shaped link; media flows.
#   2. stream    — >= STREAM_SEC of sustained delivery under 200ms RTT.
#   3. drop      — isolate link1 (172.31.77.1) in BOTH directions via iptables.
#                  The sender must mark it failed within ~SENDER_CONN_TIMEOUT and
#                  keep streaming on link2 (the survivor) to the end of the run.
#
# PASS <=> handshake <= HANDSHAKE_MAX_S UNDER 200ms RTT AND both links established
#          AND bytes_received >= MIN_BYTES AND the sender shifted off the dead
#          link within the deadline while the survivor stayed up and the stream
#          kept running (post-isolation delivery).
#
# NB (per tests/KNOWN_BUGS.md, link-drop precedent): end-to-end SRT `disconnects`
# is RECORDED but is NOT a pass gate for the isolation phase. Riding a hard
# mid-stream dual-direction link kill without an SRT break is an SRT app-layer
# property (the caller's deep send window vs ffmpeg's fixed peer-idle timeout),
# orthogonal to the sender's bonding correctness — which IS gated above (shift +
# survivor-up + sustained bytes). A production caller (cerastream/Moblin) is
# tuned to ride it through; ffmpeg's tiny defaults are not, so we do not gate it.
#
# PRIVILEGE: needs CAP_NET_ADMIN (real root / passwordless sudo, OR mapped-root
# in a user+net namespace). `netem_require` gates it functionally; without it the
# scenario prints SKIP-PRIVILEGED and exits 77 (clean skip) creating no state.
#   CI (tier blocking):  sudo tests/compat/scenarios/link-drop-high-rtt.sh
#   Local dev (no sudo): unshare -rnm bash -c 'mount -t tmpfs none /run;
#                          mkdir -p /run/netns; ip link set lo up;
#                          exec bash tests/compat/scenarios/link-drop-high-rtt.sh'
#
# Usage:
#   link-drop-high-rtt.sh [--build-dir DIR] [--keep-logs] [-h]
#
# Artifacts land in tests/compat/results/link-drop-high-rtt/ (gitignored);
# nothing is written outside the repo (Rule D).
#
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." >/dev/null 2>&1 && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/../results/link-drop-high-rtt"
NETEM_LIB="${SCRIPT_DIR}/../lib/netem.sh"

log()  { printf '%s\n' "$*" >&2; }
die()  { printf 'link-drop-high-rtt: %s\n' "$*" >&2; exit 2; }
now_ms() { date +%s%3N; }

BUILD_DIR="${SRTLA_BUILD_DIR:-}"
KEEP_LOGS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir) BUILD_DIR="${2:?--build-dir needs a value}"; shift 2 ;;
    --keep-logs) KEEP_LOGS=1; shift ;;
    -h|--help)   sed -n '2,63p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown argument '$1' (try --help)" ;;
  esac
done

for tool in ffmpeg jq ip tc iptables ping; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' not found in PATH"
done

# --------------------------------------------------------------------------- #
# Source the shaping library and gate on CAP_NET_ADMIN. netem_require is        #
# self-cleaning and returns 77 (SKIP-PRIVILEGED) when unprivileged — we         #
# propagate that verbatim so the harness treats it as a clean skip, never a     #
# silent pass. Sourcing arms netem's own EXIT trap; we install our master trap  #
# AFTER this and call netem_teardown_all from it (per the netem.sh contract).   #
# --------------------------------------------------------------------------- #
[[ -r "$NETEM_LIB" ]] || die "netem shaping library not found at $NETEM_LIB"
# shellcheck source=../lib/netem.sh
source "$NETEM_LIB"

netem_require
NETEM_RC=$?
if [[ "$NETEM_RC" -eq 77 ]]; then
  log "SKIP link-drop-high-rtt: netem unavailable (need CAP_NET_ADMIN: root, sudo, or mapped-root userns)"
  mkdir -p "$RESULTS_DIR"
  printf '{"scenario":"link-drop-high-rtt","skipped":true,"reason":"netem unavailable (no CAP_NET_ADMIN)"}\n' \
    > "${RESULTS_DIR}/result.json"
  exit 77
fi
[[ "$NETEM_RC" -eq 0 ]] || die "netem_require failed unexpectedly (rc=$NETEM_RC)"

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

# --------------------------------------------------------------------------- #
# Shaping + topology parameters.                                               #
# --------------------------------------------------------------------------- #
# netem instance name: <=4 alnum chars so the host iface stays inside IFNAMSIZ
# (15). netem.sh derives `veth-srtla-hrtt` / `npeer-hrtt` / `ns-srtla-hrtt` from
# it verbatim for short alnum names (see netem.sh _netem_slug / _netem_ns).
NETEM_NAME="hrtt"
NETEM_DELAY_MS=200
NETEM_JITTER_MS=20
NETEM_ARGS="delay ${NETEM_DELAY_MS}ms ${NETEM_JITTER_MS}ms distribution normal"

NS="ns-srtla-${NETEM_NAME}"
HOSTIF="veth-srtla-${NETEM_NAME}"
PEERIF="npeer-${NETEM_NAME}"

# A routable /24 laid over the shaped host veth: two SOURCE IPs (the bonded
# links) on the host end, one receiver IP on the netns peer end. Distinct from
# netem.sh's internal /30 so the two coexist; on-link routing sends host->RECV_IP
# out the shaped veth, so both source IPs inherit the 200ms shaping.
OVL_NET="172.31.77"
LINK1_IP="${OVL_NET}.1"
LINK2_IP="${OVL_NET}.2"
RECV_IP="${OVL_NET}.254"
OVL_PREFIX=24

SRTLA_PORT=5311
SINK_PORT=4311
LOCAL_SRT_PORT=6311

MIN_BYTES=5000              # task threshold: sustained bonded flow under 200ms RTT
SENDER_CONN_TIMEOUT_S=4     # mirrors SENDER_CONN_TIMEOUT (src/sender_logic.h)
SHIFT_DEADLINE_MS=12000     # CONN_TIMEOUT + housekeeping slack, padded for 200ms RTT
SRT_LATENCY_MS=4000         # deep SRT window so the caller rides the link transition
HANDSHAKE_MAX_S=10          # task gate: handshake <= 10s UNDER 200ms RTT
ESTABLISH_SEC=6
STREAM_SEC=30               # >= 30s sustained delivery before the drop
DROP_SEC=15
SINK_DURATION=$((ESTABLISH_SEC + STREAM_SEC + DROP_SEC + 30))

rm -rf "$RESULTS_DIR"; mkdir -p "$RESULTS_DIR"
RX_LOG="${RESULTS_DIR}/receiver.log"
TX_LOG="${RESULTS_DIR}/sender.log"
FF_LOG="${RESULTS_DIR}/ffmpeg.log"
SINK_JSON="${RESULTS_DIR}/sink.json"
IPS_FILE="${RESULTS_DIR}/ips.txt"
RESULT_JSON="${RESULTS_DIR}/result.json"

# --------------------------------------------------------------------------- #
# Echo the exact parameters this run uses (parseable in the captured output).   #
# --------------------------------------------------------------------------- #
log "================ link-drop-high-rtt parameters ================"
log "  netem        : ${NETEM_ARGS}   (instance '${NETEM_NAME}', host iface ${HOSTIF})"
log "  shaping leg  : host->netns egress (single-leg => RTT ~= ${NETEM_DELAY_MS}ms)"
log "  link1 (src)  : ${LINK1_IP}   link2 (src): ${LINK2_IP}   receiver: ${RECV_IP}:${SRTLA_PORT}"
log "  thresholds   : handshake<=${HANDSHAKE_MAX_S}s  min_bytes=${MIN_BYTES}  shift_deadline=${SHIFT_DEADLINE_MS}ms"
log "  timing       : establish=${ESTABLISH_SEC}s stream=${STREAM_SEC}s drop=${DROP_SEC}s srt_latency=${SRT_LATENCY_MS}ms"
log "  conn_timeout : ${SENDER_CONN_TIMEOUT_S}s (SENDER_CONN_TIMEOUT)   build: ${BUILD_DIR}"
log "  disconnects  : recorded, NOT a pass gate for the isolation phase (KNOWN_BUGS.md)"
log "=============================================================="

# --------------------------------------------------------------------------- #
# Process + iptables state, and the master cleanup trap. We OVERRIDE netem.sh's  #
# trap, so cleanup MUST call netem_teardown_all to drop the qdisc/veth/netns.    #
# --------------------------------------------------------------------------- #
PIDS=()
DROP_RULES_ACTIVE=0
track() { PIDS+=("$1"); }

drop_link1() {
  # Kill link1 in BOTH directions (link-drop technique, adapted to the netns
  # topology): upstream leaves the host as OUTPUT; the receiver's reply enters
  # the host from the netns as INPUT. Dropping both isolates link1 only.
  iptables -I OUTPUT -s "$LINK1_IP" -d "$RECV_IP"  -p udp -j DROP 2>/dev/null
  iptables -I INPUT  -s "$RECV_IP"  -d "$LINK1_IP" -p udp -j DROP 2>/dev/null
  DROP_RULES_ACTIVE=1
}
restore_link1() {
  [[ "$DROP_RULES_ACTIVE" -eq 1 ]] || return 0
  iptables -D OUTPUT -s "$LINK1_IP" -d "$RECV_IP"  -p udp -j DROP 2>/dev/null
  iptables -D INPUT  -s "$RECV_IP"  -d "$LINK1_IP" -p udp -j DROP 2>/dev/null
  DROP_RULES_ACTIVE=0
}

cleanup() {
  restore_link1
  local p
  for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill -TERM "$p" 2>/dev/null; done
  netem_teardown_all   # drops qdisc + veth (both ends) + netns => zero residue
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

# grep -c always prints one integer; capture it so a no-match exit 1 does not
# append a second "0" line (which would corrupt the numeric comparisons).
count_re() { local n; n=$(grep -Ec -- "$2" "$1" 2>/dev/null); printf '%s' "${n:-0}"; }

# --------------------------------------------------------------------------- #
# Build the shaped topology: one netem-shaped veth+netns, then overlay the /24   #
# so two source IPs and the receiver IP all sit on the shaped link.             #
# --------------------------------------------------------------------------- #
log "==> shaping: netem_setup ${NETEM_NAME} ${NETEM_ARGS}"
ip link set lo up 2>/dev/null || true   # host SRT caller binds 127.0.0.1 (no-op under sudo)
netem_setup "$NETEM_NAME" $NETEM_ARGS || die "netem_setup failed (could not shape the link)"

ip addr add "${LINK1_IP}/${OVL_PREFIX}" dev "$HOSTIF" 2>/dev/null \
  || die "could not add ${LINK1_IP} to ${HOSTIF}"
ip addr add "${LINK2_IP}/${OVL_PREFIX}" dev "$HOSTIF" 2>/dev/null \
  || die "could not add ${LINK2_IP} to ${HOSTIF}"
ip netns exec "$NS" ip addr add "${RECV_IP}/${OVL_PREFIX}" dev "$PEERIF" 2>/dev/null \
  || die "could not add ${RECV_IP} to ${PEERIF} (netns ${NS})"

# Sanity: the receiver IP must answer across the shaped veth before we stream.
if ! ping -c 1 -W 3 "$RECV_IP" >/dev/null 2>&1; then
  die "receiver IP ${RECV_IP} unreachable across the shaped veth"
fi

# --------------------------------------------------------------------------- #
# Phase 1 — establish the bonded 2-link stream through the shaped link.         #
# srt-sink + srtla_rec run INSIDE the netns so the sender->receiver data path    #
# egresses the shaped host veth. srt-sink stays in a backgrounded MAIN-shell     #
# process (never $(...)) so the teardown wait can block on its JSON flush.       #
# --------------------------------------------------------------------------- #
log "==> phase 1: establish 2-link bonded stream under ${NETEM_DELAY_MS}ms RTT"

ip netns exec "$NS" "$SRT_SINK" --port "$SINK_PORT" --host 127.0.0.1 --result "$SINK_JSON" \
            --latency "$SRT_LATENCY_MS" --duration "$SINK_DURATION" \
            >"${SINK_JSON%.json}.log" 2>&1 &
SINK_PID=$!; track "$SINK_PID"
sleep 0.5

ip netns exec "$NS" "$SRTLA_REC" --srtla_port "$SRTLA_PORT" --srt_hostname 127.0.0.1 \
             --srt_port "$SINK_PORT" --log_level trace >"$RX_LOG" 2>&1 &
RX_PID=$!; track "$RX_PID"
wait_for_marker "$RX_LOG" "srtla_rec is now running" 5 || die "receiver never came up"

printf '%s\n%s\n' "$LINK1_IP" "$LINK2_IP" > "$IPS_FILE"
T_SEND_MS="$(now_ms)"
"$SRTLA_SEND" "$LOCAL_SRT_PORT" "$RECV_IP" "$SRTLA_PORT" "$IPS_FILE" >"$TX_LOG" 2>&1 &
TX_PID=$!; track "$TX_PID"
sleep 0.6

# The SRT caller must ride a multi-second link transition: a deep send buffer
# absorbs the stall while srtla shifts off the dead link, and a generous I/O
# timeout stops libsrt aborting the muxer the instant a send blocks. A real
# SRTLA caller (cerastream/Moblin) is tuned the same way; ffmpeg's tiny defaults
# would otherwise tear the stream down. SRT latency/timeout options are in
# MICROSECONDS. latency 4000ms >> 200ms RTT, so the window is not RTT-starved.
SRT_LATENCY_US=$(( SRT_LATENCY_MS * 1000 ))
SRT_OPTS="mode=caller&transtype=live&latency=${SRT_LATENCY_US}&peerlatency=${SRT_LATENCY_US}&sndbuf=24000000&timeout=30000000"
ffmpeg -hide_banner -loglevel warning -re \
  -f lavfi -i testsrc2=size=320x240:rate=25 -c:v mpeg2video -b:v 700k -f mpegts \
  "srt://127.0.0.1:${LOCAL_SRT_PORT}?${SRT_OPTS}" \
  >"$FF_LOG" 2>&1 &
FF_PID=$!; track "$FF_PID"

# Handshake under 200ms RTT must complete within HANDSHAKE_MAX_S.
handshake=false
handshake_ms=-1
if wait_for_marker "$RX_LOG" "Group registered" "$HANDSHAKE_MAX_S"; then
  handshake=true
  handshake_ms=$(( $(now_ms) - T_SEND_MS ))
fi
log "    handshake=${handshake} handshake_ms=${handshake_ms} (max ${HANDSHAKE_MAX_S}s)"

# Both source IPs must be added by the sender (the two bonded links).
both_links_added=false
if grep -q -- "$LINK1_IP" "$TX_LOG" 2>/dev/null \
   && grep -q -- "$LINK2_IP" "$TX_LOG" 2>/dev/null; then
  both_links_added=true
fi

sleep "$ESTABLISH_SEC"

# --------------------------------------------------------------------------- #
# Phase 2 — sustained streaming under 200ms RTT (>= STREAM_SEC).                 #
# --------------------------------------------------------------------------- #
log "==> phase 2: stream ${STREAM_SEC}s under ${NETEM_DELAY_MS}ms RTT"
sleep "$STREAM_SEC"

# --------------------------------------------------------------------------- #
# Phase 3 — isolate link1; the survivor must carry the stream to the end.       #
# --------------------------------------------------------------------------- #
log "==> phase 3: isolate link1 (${LINK1_IP}) for ${DROP_SEC}s"

# Snapshot per-link failure markers BEFORE the drop so we only count NEW ones
# (the bootstrap handshake can log a transient reconnect at startup).
link1_failed_pre=$(count_re "$TX_LOG" "${LINK1_IP}.*connection failed")
link2_failed_pre=$(count_re "$TX_LOG" "${LINK2_IP}.*connection failed")

DROP_T0="$(now_ms)"
drop_link1

# A NEW "connection failed, attempting to reconnect" for link1 proves the drop
# took hold and the sender stopped trusting it (traffic shifts to the survivor).
link1_failed=false
shift_ms=-1
deadline=$(( DROP_T0 + SHIFT_DEADLINE_MS ))
while [[ "$(now_ms)" -lt "$deadline" ]]; do
  link1_failed_now=$(count_re "$TX_LOG" "${LINK1_IP}.*connection failed")
  if [[ "$link1_failed_now" -gt "$link1_failed_pre" ]]; then
    link1_failed=true
    shift_ms=$(( $(now_ms) - DROP_T0 ))
    break
  fi
  sleep 0.2
done
log "    link1_failed=${link1_failed} shift_ms=${shift_ms} (deadline ${SHIFT_DEADLINE_MS}ms)"

# Hold the drop the rest of the window so the survivor is exercised under load.
elapsed=$(( $(now_ms) - DROP_T0 ))
remain=$(( DROP_SEC * 1000 - elapsed ))
[[ "$remain" -gt 0 ]] && sleep "$(awk "BEGIN{print $remain/1000}")"

# The survivor (link2) must NOT have failed across the whole drop window, and the
# stream processes must still be alive — together this is post-isolation delivery
# (the survivor kept carrying media while link1 was dead).
link2_failed_now=$(count_re "$TX_LOG" "${LINK2_IP}.*connection failed")
survivor_stayed_up=false
[[ "$link2_failed_now" -le "$link2_failed_pre" ]] && survivor_stayed_up=true

stream_alive=false
if kill -0 "$TX_PID" 2>/dev/null && kill -0 "$FF_PID" 2>/dev/null; then
  stream_alive=true
fi
log "    survivor_stayed_up=${survivor_stayed_up} stream_alive=${stream_alive}"

# --------------------------------------------------------------------------- #
# Teardown — SINK FIRST so the intentional ffmpeg/sender stop is not counted as  #
# a mid-stream disconnect (the sink only tallies a break while still running).   #
# --------------------------------------------------------------------------- #
stop_pid "$SINK_PID"
[[ -n "${FF_PID:-}" ]] && { kill -TERM "$FF_PID" 2>/dev/null; wait "$FF_PID" 2>/dev/null; }
stop_pid "$TX_PID"
stop_pid "$RX_PID"

bytes="$(jq -r '.bytes_received // 0' "$SINK_JSON" 2>/dev/null || echo 0)"
disc="$(jq -r '.disconnects // -1'   "$SINK_JSON" 2>/dev/null || echo -1)"
[[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
[[ "$disc" =~ ^-?[0-9]+$ ]] || disc=-1

# --------------------------------------------------------------------------- #
# Verdict.                                                                      #
# --------------------------------------------------------------------------- #
establish_ok=false
[[ "$handshake" == true && "$handshake_ms" -ge 0 && "$handshake_ms" -le $((HANDSHAKE_MAX_S * 1000)) \
   && "$both_links_added" == true ]] && establish_ok=true

# Deterministic sender behavior: within the deadline the sender marks the dead
# link failed AND the survivor never fails AND the stream is still running.
shift_ok=false
[[ "$link1_failed" == true && "$shift_ms" -ge 0 && "$shift_ms" -le "$SHIFT_DEADLINE_MS" \
   && "$survivor_stayed_up" == true && "$stream_alive" == true ]] && shift_ok=true

# The survivor carried real media under 200ms RTT: a substantial bonded stream
# reached the sink across the whole window (which extends past the isolation).
survivor_ok=false
[[ "$bytes" -ge "$MIN_BYTES" ]] && survivor_ok=true

pass=false
[[ "$establish_ok" == true && "$shift_ok" == true && "$survivor_ok" == true ]] && pass=true

jq -n \
  --argjson pass "$pass" \
  --argjson establish_ok "$establish_ok" \
  --argjson shift_ok "$shift_ok" \
  --argjson survivor_ok "$survivor_ok" \
  --argjson handshake "$handshake" \
  --argjson handshake_ms "$handshake_ms" \
  --argjson handshake_max_ms $((HANDSHAKE_MAX_S * 1000)) \
  --argjson both_links_added "$both_links_added" \
  --argjson link1_failed "$link1_failed" \
  --argjson survivor_stayed_up "$survivor_stayed_up" \
  --argjson stream_alive "$stream_alive" \
  --argjson shift_ms "$shift_ms" \
  --argjson shift_deadline_ms "$SHIFT_DEADLINE_MS" \
  --argjson bytes "$bytes" \
  --argjson min_bytes "$MIN_BYTES" \
  --argjson disconnects "$disc" \
  --argjson conn_timeout_s "$SENDER_CONN_TIMEOUT_S" \
  --argjson srt_latency_ms "$SRT_LATENCY_MS" \
  --arg netem "$NETEM_ARGS" \
  --argjson rtt_ms "$NETEM_DELAY_MS" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    scenario:"link-drop-high-rtt", pass:$pass,
    shaping:{netem:$netem, rtt_ms:$rtt_ms, leg:"single (host->netns egress)"},
    criteria:{establish_ok:$establish_ok, shift_ok:$shift_ok, survivor_ok:$survivor_ok},
    establish:{handshake:$handshake, handshake_ms:$handshake_ms,
               handshake_max_ms:$handshake_max_ms, both_links_added:$both_links_added},
    drop:{link1_failed:$link1_failed, survivor_stayed_up:$survivor_stayed_up,
          stream_alive:$stream_alive, shift_ms:$shift_ms,
          shift_deadline_ms:$shift_deadline_ms, conn_timeout_s:$conn_timeout_s},
    survivor:{bytes_received:$bytes, min_bytes:$min_bytes,
              disconnects_informational:$disconnects, srt_latency_ms:$srt_latency_ms},
    timestamp:$ts
  }' > "$RESULT_JSON"

log ""
log "================ link-drop-high-rtt summary ================"
log "  establish_ok=${establish_ok} (handshake=${handshake} ${handshake_ms}ms<=${HANDSHAKE_MAX_S}s both_links=${both_links_added})"
log "  shift_ok=${shift_ok} (link1_failed=${link1_failed} shift_ms=${shift_ms} survivor_up=${survivor_stayed_up} stream_alive=${stream_alive})"
log "  survivor_ok=${survivor_ok} (bytes=${bytes}>=${MIN_BYTES}; disc=${disc} informational)"
log "  netem=${NETEM_ARGS}  result: ${RESULT_JSON}"
log "==========================================================="

if [[ "$KEEP_LOGS" -eq 0 && "$pass" == true ]]; then
  rm -f "$RX_LOG" "$TX_LOG" "$FF_LOG" "${SINK_JSON%.json}.log" "$IPS_FILE"
fi

if [[ "$pass" == true ]]; then log "PASS"; exit 0; else log "FAIL"; exit 1; fi

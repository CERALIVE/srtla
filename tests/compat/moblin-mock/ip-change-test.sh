#!/usr/bin/env bash
#
# ip-change-test.sh — Moblin mid-stream source-IP-change conformance scenario.
#
# Drives moblin_mock.py through Moblin's network-path-change behaviour ([B4] in
# BEHAVIOR.md) against our real srtla_rec + srt-sink, then asserts the receiver's
# documented reaction.
#
#   ffmpeg (SRT) -> moblin_mock [uplink 127.0.0.1] -> srtla_rec -> srt-sink
#                                     |
#                       at T+N s: rebind uplink -> 127.0.0.2,
#                       re-register into the SAME group (REG2, no new REG1)
#
# DOCUMENTED EXPECTATION (derived from source, asserted below):
#   On a mid-stream source-IP change, srtla_rec keeps the EXISTING group; the new
#   source address re-registers INTO that same group via REG2/REG3 (no new REG1,
#   no second group) and the SRT stream continues without a disconnect.
#     - srtla/src/protocol/srtla_handler.cpp:242-308 (register_connection finds
#       the group by id and replies REG3 for a new source address)
#     - Moblin SrtlaClient.swift:300-346 / RemoteConnection.swift:202-209
#
# Exit 0 = expectation held (PASS); non-zero = FAIL. Self-contained: all runtime
# artifacts go to a private temp dir (repo-local, no workspace escapes).
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." >/dev/null 2>&1 && pwd)"

# --- options ---------------------------------------------------------------- #
CHANGE_AT=4          # seconds after registration to change the source IP
CHANGE_TO=127.0.0.2  # new uplink source IP (127.0.0.0/8 is all loopback)
DURATION=14          # total measurement window (s)
SINK_PORT=4121 SRTLA_PORT=5121 LOCAL_SRT_PORT=6121
BUILD_DIR="${SRTLA_BUILD_DIR:-}"
WORK=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-dir)  BUILD_DIR="${2:?}"; shift 2 ;;
    --work-dir)   WORK="${2:?}"; shift 2 ;;
    --change-at)  CHANGE_AT="${2:?}"; shift 2 ;;
    --duration)   DURATION="${2:?}"; shift 2 ;;
    -h|--help)    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            echo "ip-change-test: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

log() { printf '%s\n' "$*"; }

# --- resolve binaries ------------------------------------------------------- #
resolve_build_dir() {
  local c
  for c in "$BUILD_DIR" "${REPO_ROOT}/build" /tmp/srtla-build; do
    [[ -n "$c" ]] || continue
    if [[ -x "${c}/srtla_rec" && -x "${c}/tests/compat/srt-sink/srt-sink" ]]; then
      printf '%s' "$c"; return 0
    fi
  done
  return 1
}
BUILD_DIR="$(resolve_build_dir)" || {
  echo "ip-change-test: no build dir with srtla_rec + srt-sink." >&2
  echo "  build with: cmake -B build -DBUILD_COMPAT_TESTS=ON && cmake --build build -j" >&2
  exit 2
}
SRTLA_REC="${BUILD_DIR}/srtla_rec"
SRT_SINK="${BUILD_DIR}/tests/compat/srt-sink/srt-sink"
MOCK="${SCRIPT_DIR}/moblin_mock.py"

for tool in ffmpeg jq python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "ip-change-test: '$tool' not found" >&2; exit 2; }
done

[[ -n "$WORK" ]] || WORK="$(mktemp -d -t moblin-ipchange.XXXXXX)"
mkdir -p "$WORK"

PIDS=()
cleanup() { local p; for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill -TERM "$p" 2>/dev/null; done; }
trap cleanup EXIT INT TERM

# --- run -------------------------------------------------------------------- #
log "== Moblin IP-change conformance scenario =="
log "   build-dir : ${BUILD_DIR}"
log "   work-dir  : ${WORK}"
log "   change    : 127.0.0.1 -> ${CHANGE_TO} at registration+${CHANGE_AT}s, window ${DURATION}s"
log ""

ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=320x240:rate=25 -t 5 \
  -c:v mpeg2video -b:v 1M -f mpegts "${WORK}/test.ts" >/dev/null 2>&1 \
  || { echo "ip-change-test: failed to generate test.ts" >&2; exit 2; }

"$SRT_SINK" --port "$SINK_PORT" --host 127.0.0.1 --result "${WORK}/sink.json" \
            --duration $((DURATION + 10)) >"${WORK}/sink.log" 2>&1 &
PIDS+=($!); sleep 0.5

"$SRTLA_REC" --srtla_port "$SRTLA_PORT" --srt_hostname 127.0.0.1 --srt_port "$SINK_PORT" \
             --log_level trace >"${WORK}/rx.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 50); do grep -q "srtla_rec is now running" "${WORK}/rx.log" 2>/dev/null && break; sleep 0.1; done

python3 "$MOCK" --receiver-host 127.0.0.1 --receiver-port "$SRTLA_PORT" \
  --local-srt-port "$LOCAL_SRT_PORT" --bind-ip 127.0.0.1 \
  --ip-change-at-sec "$CHANGE_AT" --ip-change-to "$CHANGE_TO" >"${WORK}/mock.log" 2>&1 &
PIDS+=($!)
for _ in $(seq 1 50); do grep -q "registered" "${WORK}/mock.log" 2>/dev/null && break; sleep 0.1; done

ffmpeg -hide_banner -loglevel warning -re -stream_loop -1 -i "${WORK}/test.ts" -c copy -f mpegts \
  "srt://127.0.0.1:${LOCAL_SRT_PORT}?mode=caller&transtype=live" >"${WORK}/ff.log" 2>&1 &
PIDS+=($!)

sleep "$DURATION"

# teardown: sink first (so intentional stop is not counted as a disconnect)
kill -TERM "${PIDS[0]}" 2>/dev/null; sleep 0.5
cleanup; sleep 0.5

# --- gather ----------------------------------------------------------------- #
bytes="$(jq -r '.bytes_received // 0' "${WORK}/sink.json" 2>/dev/null || echo 0)"
disc="$(jq -r '.disconnects // -1' "${WORK}/sink.json" 2>/dev/null || echo -1)"

# grep -c always prints a single count; capture it without `|| echo` (which would
# append a second line and corrupt the later arithmetic) and default empty to 0.
group_regs="$(grep -c "Group registered" "${WORK}/rx.log" 2>/dev/null)"; group_regs="${group_regs:-0}"
group_ptr="$(grep "Group registered" "${WORK}/rx.log" 2>/dev/null | grep -oE '0x[0-9a-f]+' | head -n1)"
conn_regs_same_group=0
if [[ -n "$group_ptr" ]]; then
  conn_regs_same_group="$(grep "Connection registration" "${WORK}/rx.log" 2>/dev/null | grep -c "$group_ptr")"
  conn_regs_same_group="${conn_regs_same_group:-0}"
fi
mock_changed="$(grep -c "new uplink ${CHANGE_TO} registered into existing group" "${WORK}/mock.log" 2>/dev/null)"; mock_changed="${mock_changed:-0}"
mock_reconnects="$(grep -cE "reconnect|no receiver packet in 5s" "${WORK}/mock.log" 2>/dev/null)"; mock_reconnects="${mock_reconnects:-0}"

# --- assert ----------------------------------------------------------------- #
fail=0
assert() { # label expected actual ok
  local label="$1" expected="$2" actual="$3" ok="$4"
  if [[ "$ok" == 1 ]]; then printf '  PASS  %-44s expected %-22s got %s\n' "$label" "$expected" "$actual"
  else printf '  FAIL  %-44s expected %-22s got %s\n' "$label" "$expected" "$actual"; fail=1; fi
}

log ""
log "-- assertions (DOCUMENTED EXPECTATION: existing group continues via re-registration) --"
assert "single group (not recreated)"        "exactly 1"   "$group_regs"              "$([[ "$group_regs" -eq 1 ]] && echo 1 || echo 0)"
assert "re-registration into same group"     ">= 2"        "$conn_regs_same_group"    "$([[ "$conn_regs_same_group" -ge 2 ]] && echo 1 || echo 0)"
assert "mock rebound 127.0.0.1->${CHANGE_TO}" ">= 1"       "$mock_changed"            "$([[ "$mock_changed" -ge 1 ]] && echo 1 || echo 0)"
assert "no mock reconnect/watchdog trip"      "0"          "$mock_reconnects"         "$([[ "$mock_reconnects" -eq 0 ]] && echo 1 || echo 0)"
assert "stream continuity: disconnects"       "0"          "$disc"                    "$([[ "$disc" -eq 0 ]] && echo 1 || echo 0)"
assert "stream continuity: bytes_received"    ">= 1000"    "$bytes"                   "$([[ "$bytes" -ge 1000 ]] && echo 1 || echo 0)"

log ""
log "-- receiver registration timeline (one group, two source endpoints) --"
grep -nE "No group found|Group registered|Connection registration" "${WORK}/rx.log" 2>/dev/null | sed 's/^/   /'
log ""
log "-- mock IP-change log --"
grep -E "IP-CHANGE|registered" "${WORK}/mock.log" 2>/dev/null | sed 's/^/   /'

log ""
if [[ "$fail" -eq 0 ]]; then
  log "VERDICT: PASS — existing group continued; ${CHANGE_TO} re-registered into group ${group_ptr}; no disconnect."
  exit 0
else
  log "VERDICT: FAIL — see assertions above. Artifacts in ${WORK}"
  exit 1
fi

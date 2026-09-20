#!/bin/bash
# Compat-test entrypoint for BELABOX/srtla_send.
#
# Env vars (all optional):
#   RECEIVER_HOST   target srtla_rec host          (default 127.0.0.1)
#   RECEIVER_PORT   target srtla_rec UDP port       (default 5000)
#   LOCAL_SRT_PORT  local UDP port the feeder uses  (default 6000)
#   IPS             source uplink IPs, comma/space/newline separated
#                   (default 127.0.0.1)
#
# Starts srtla_send, then feeds a looping MPEG-TS test pattern into it as an
# SRT caller stream so the bonded link carries real traffic in CI.
set -euo pipefail

RECEIVER_HOST="${RECEIVER_HOST:-127.0.0.1}"
RECEIVER_PORT="${RECEIVER_PORT:-5000}"
LOCAL_SRT_PORT="${LOCAL_SRT_PORT:-6000}"
IPS="${IPS:-127.0.0.1}"

IPS_FILE="$(mktemp)"
printf '%s\n' "${IPS}" | tr ', ' '\n\n' | sed '/^[[:space:]]*$/d' > "${IPS_FILE}"

echo "[entrypoint] belabox srtla_send -> ${RECEIVER_HOST}:${RECEIVER_PORT} (local SRT port ${LOCAL_SRT_PORT})"
echo "[entrypoint] uplink source IPs:"
cat "${IPS_FILE}"

# BELABOX CLI: srtla_send SRT_LISTEN_PORT SRTLA_HOST SRTLA_PORT BIND_IPS_FILE
srtla_send "${LOCAL_SRT_PORT}" "${RECEIVER_HOST}" "${RECEIVER_PORT}" "${IPS_FILE}" &
SENDER_PID=$!
trap 'kill "${SENDER_PID}" 2>/dev/null || true' EXIT INT TERM
sleep 1

exec ffmpeg -hide_banner -loglevel warning \
    -re -stream_loop -1 -i /assets/test.ts \
    -c copy -f mpegts \
    "srt://127.0.0.1:${LOCAL_SRT_PORT}?mode=caller&transtype=live"

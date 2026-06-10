#!/bin/bash
# Compat-test entrypoint for the Moblin SRTLA conformance mock sender.
#
# Env vars (all optional):
#   RECEIVER_HOST   target srtla_rec host             (default 127.0.0.1)
#   RECEIVER_PORT   target srtla_rec UDP port          (default 5000)
#   LOCAL_SRT_PORT  local UDP port the feeder uses     (default 6000)
#   IPS             source uplink IPs, comma/space/newline separated
#                   (first IP is the mock's SRTLA uplink bind IP; default 127.0.0.1)
#
# Starts moblin_mock.py (the SRTLA layer), waits for it to register with the
# receiver via Moblin's probe->NGP->REG1->REG2->REG3 handshake, then feeds a
# looping MPEG-TS test pattern into it as an SRT caller stream so the bonded link
# carries real traffic. moblin_mock relays the SRT packets transparently.
set -uo pipefail

RECEIVER_HOST="${RECEIVER_HOST:-127.0.0.1}"
RECEIVER_PORT="${RECEIVER_PORT:-5000}"
LOCAL_SRT_PORT="${LOCAL_SRT_PORT:-6000}"
IPS="${IPS:-127.0.0.1}"

# First IP wins as the uplink bind IP (the mock runs a single active uplink).
BIND_IP="$(printf '%s\n' "${IPS}" | tr ', ' '\n\n' | sed '/^[[:space:]]*$/d' | head -n1)"
BIND_IP="${BIND_IP:-127.0.0.1}"

echo "[entrypoint] moblin-mock -> ${RECEIVER_HOST}:${RECEIVER_PORT} (local SRT port ${LOCAL_SRT_PORT}, uplink ${BIND_IP})"

MOCK_LOG="$(mktemp)"
python3 /usr/local/bin/moblin_mock.py \
    --receiver-host "${RECEIVER_HOST}" \
    --receiver-port "${RECEIVER_PORT}" \
    --local-srt-port "${LOCAL_SRT_PORT}" \
    --bind-ip "${BIND_IP}" 2>"${MOCK_LOG}" &
MOCK_PID=$!
trap 'kill "${MOCK_PID}" 2>/dev/null || true' EXIT INT TERM

# Wait (up to ~4s) for the SRTLA handshake to complete before feeding SRT, so the
# first SRT handshake packets are not dropped pre-registration.
for _ in $(seq 1 40); do
    kill -0 "${MOCK_PID}" 2>/dev/null || { echo "[entrypoint] mock exited early:"; cat "${MOCK_LOG}"; exit 1; }
    grep -q "registered" "${MOCK_LOG}" && break
    sleep 0.1
done
sed 's/^/[mock] /' "${MOCK_LOG}" || true

exec ffmpeg -hide_banner -loglevel warning \
    -re -stream_loop -1 -i /assets/test.ts \
    -c copy -f mpegts \
    "srt://127.0.0.1:${LOCAL_SRT_PORT}?mode=caller&transtype=live"

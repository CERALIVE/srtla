#!/bin/sh
# OpenIRL srtla_rec receiver entrypoint.
# Maps the compat-harness env contract onto srtla_rec's flags:
#   srtla_rec --srtla_port P --srt_hostname H --srt_port P2
set -eu

SRTLA_PORT="${SRTLA_PORT:-5000}"
SRT_TARGET_HOST="${SRT_TARGET_HOST:-127.0.0.1}"
SRT_TARGET_PORT="${SRT_TARGET_PORT:-4001}"

echo "openirl-receiver: srtla_rec --srtla_port ${SRTLA_PORT} -> ${SRT_TARGET_HOST}:${SRT_TARGET_PORT}"
exec srtla_rec \
  --srtla_port "${SRTLA_PORT}" \
  --srt_hostname "${SRT_TARGET_HOST}" \
  --srt_port "${SRT_TARGET_PORT}"

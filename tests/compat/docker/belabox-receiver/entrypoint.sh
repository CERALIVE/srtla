#!/bin/sh
# BELABOX srtla_rec receiver entrypoint.
# Maps the compat-harness env contract onto srtla_rec's positional CLI:
#   srtla_rec SRTLA_LISTEN_PORT SRT_HOST SRT_PORT
set -eu

SRTLA_PORT="${SRTLA_PORT:-5000}"
SRT_TARGET_HOST="${SRT_TARGET_HOST:-127.0.0.1}"
SRT_TARGET_PORT="${SRT_TARGET_PORT:-4001}"

echo "belabox-receiver: srtla_rec ${SRTLA_PORT} -> ${SRT_TARGET_HOST}:${SRT_TARGET_PORT}"
exec srtla_rec "${SRTLA_PORT}" "${SRT_TARGET_HOST}" "${SRT_TARGET_PORT}"

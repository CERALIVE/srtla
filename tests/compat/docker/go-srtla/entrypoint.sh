#!/bin/sh
# go-srtla receiver entrypoint.
# Maps the compat-harness env contract onto go-srtla's flags:
#   go-srtla -srtla_port P -srt_hostname H -srt_port P2
set -eu

SRTLA_PORT="${SRTLA_PORT:-5000}"
SRT_TARGET_HOST="${SRT_TARGET_HOST:-127.0.0.1}"
SRT_TARGET_PORT="${SRT_TARGET_PORT:-4001}"

echo "go-srtla: -srtla_port ${SRTLA_PORT} -> ${SRT_TARGET_HOST}:${SRT_TARGET_PORT}"
exec go-srtla \
  -srtla_port "${SRTLA_PORT}" \
  -srt_hostname "${SRT_TARGET_HOST}" \
  -srt_port "${SRT_TARGET_PORT}"

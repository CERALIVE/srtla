#!/bin/sh
# go-irl receiver entrypoint.
#
# Headless mode: -mode=server
#   go-irl is a full IRL streaming app (SRTLA receiver + SRT proxy + browser
#   source + WebSocket UI). `-mode=server` runs ONLY the SRTLA receiver
#   component (runSrtla); it does NOT start the browser source, SRT proxy, or
#   WebSocket server. That is the receiver-only invocation for compat testing.
#
# NOTE: server-mode flags use HYPHENS (-srtla-port/-srt-host/-srt-port), unlike
# go-srtla which uses underscores. The two are different binaries.
set -eu

SRTLA_PORT="${SRTLA_PORT:-5000}"
SRT_TARGET_HOST="${SRT_TARGET_HOST:-127.0.0.1}"
SRT_TARGET_PORT="${SRT_TARGET_PORT:-4001}"

echo "go-irl: -mode=server -srtla-port=${SRTLA_PORT} -> ${SRT_TARGET_HOST}:${SRT_TARGET_PORT}"
exec go-irl \
  -mode=server \
  -srtla-port="${SRTLA_PORT}" \
  -srt-host="${SRT_TARGET_HOST}" \
  -srt-port="${SRT_TARGET_PORT}"

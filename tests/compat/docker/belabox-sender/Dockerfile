# BELABOX/srtla sender — compat test image.
# Pinned to a specific upstream commit (SHA only; never a branch/latest).
# Default PIN tracks the BELABOX/srtla compat entry in tests/compat/matrix.yaml.
#
# Build:
#   docker build --platform linux/amd64 -t compat/belabox-sender .
#   docker build --build-arg PIN=<sha> ...   # override pin
#
# BELABOX/srtla is a pure-C UDP transport proxy; it does NOT link libsrt.
# Its Makefile derives VERSION from `git rev-parse`, so the build stage keeps
# the cloned .git directory available during `make`.

ARG PIN=37862da3d0c13b46956efd3f88877053293d97d6

# --- build stage -----------------------------------------------------------
FROM ubuntu:22.04 AS builder
ARG PIN
RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates build-essential \
    && rm -rf /var/lib/apt/lists/*
RUN git clone https://github.com/BELABOX/srtla /src \
    && cd /src \
    && git checkout "${PIN}" \
    && make srtla_send \
    && test -x /src/srtla_send

# --- runtime stage ---------------------------------------------------------
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/srtla_send /usr/local/bin/srtla_send

# Pre-generate a small loopable MPEG-TS test pattern used as the SRT source.
RUN mkdir -p /assets \
    && ffmpeg -hide_banner -loglevel error \
        -f lavfi -i testsrc2=size=320x240:rate=25 -t 5 \
        -c:v mpeg2video -b:v 1M -f mpegts /assets/test.ts \
    && test -s /assets/test.ts

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

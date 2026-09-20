# irlserver/srtla_send (Rust) sender — compat test image.
# Pinned to the v3.0.0 release commit (SHA only; never a tag/branch/latest).
# Default PIN tracks the irlserver/srtla_send compat entry in
# tests/compat/matrix.yaml.
#
# Build:
#   docker build --platform linux/amd64 -t compat/irlserver-send .
#   docker build --build-arg PIN=<sha> ...   # override pin
#
# v3.0.0 declares edition 2024 / rust-version 1.87 and builds on stable Rust.
# build.rs shells out to `git rev-parse`, so the cloned .git stays available
# during `cargo build`.

ARG PIN=ef95926918d8a4a87579c13c19a3d38dde4ca381

# --- build stage -----------------------------------------------------------
FROM rust:1.88-slim-bookworm AS builder
ARG PIN
RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates build-essential cmake pkg-config \
    && rm -rf /var/lib/apt/lists/*
RUN git clone https://github.com/irlserver/srtla_send /src \
    && cd /src \
    && git checkout "${PIN}"
WORKDIR /src
# The committed .cargo/config.toml pins `-D warnings` for upstream CI lint.
# That is irrelevant for a release build here and would let a slightly newer
# compiler's warnings break the build, so drop it before compiling.
RUN rm -f .cargo/config.toml \
    && cargo build --release --locked \
    && test -x target/release/srtla_send

# --- runtime stage ---------------------------------------------------------
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/target/release/srtla_send /usr/local/bin/srtla_send

# Pre-generate a small loopable MPEG-TS test pattern used as the SRT source.
RUN mkdir -p /assets \
    && ffmpeg -hide_banner -loglevel error \
        -f lavfi -i testsrc2=size=320x240:rate=25 -t 5 \
        -c:v mpeg2video -b:v 1M -f mpegts /assets/test.ts \
    && test -s /assets/test.ts

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]

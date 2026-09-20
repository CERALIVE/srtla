# CERALIVE/srtla-send-rs (Rust) sender — compat test image.
#
# Built FROM SOURCE at a git ref. This repo consumes no sender release artifact
# and no .deb: the pair under test is whatever the named branch currently is, so
# a compat run can never silently measure a stale published binary.
#
# The default REF tracks the ceralive-srtla-send-rs entry in
# tests/compat/matrix.yaml. It is a BRANCH, not a SHA, because the hard-fork
# sender branch is still advancing and is renamed by the canonical-swap step;
# gen-ci-matrix.sh passes the registry value through as --build-arg REF=<value>,
# so pinning later is a matrix.yaml edit with no Dockerfile change.
#
# Build:
#   docker build --platform linux/amd64 -t compat/ceralive-srtla-send-rs .
#   docker build --build-arg REF=<sha|branch|tag> ...
#
# The sender declares edition 2024 and a pinned nightly in rust-toolchain.toml;
# the toolchain image below installs rustup so that pin is honoured verbatim
# rather than silently overridden. build.rs shells out to `git rev-parse`, so
# the cloned .git stays available during `cargo build`.

ARG REF=upstream/v4

# --- build stage -----------------------------------------------------------
FROM rust:1.88-slim-bookworm AS builder
ARG REF
RUN apt-get update && apt-get install -y --no-install-recommends \
        git ca-certificates build-essential cmake pkg-config \
    && rm -rf /var/lib/apt/lists/*
RUN git clone https://github.com/CERALIVE/srtla-send-rs /src \
    && cd /src \
    && git checkout "${REF}"
WORKDIR /src
# rust-toolchain.toml pins an exact nightly for a reproducible device build.
# Install it explicitly so the build fails loudly on a missing toolchain instead
# of quietly compiling with the image's stable compiler.
RUN if [ -f rust-toolchain.toml ]; then rustup toolchain install --profile minimal; fi
# A committed .cargo/config.toml may pin `-D warnings` for the sender's own CI
# lint. That is irrelevant for a release build here and would let a slightly
# newer compiler's warnings break the image, so drop it before compiling.
RUN rm -f .cargo/config.toml \
    && cargo build --release --locked --bin srtla_send \
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

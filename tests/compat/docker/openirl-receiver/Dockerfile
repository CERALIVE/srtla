# OpenIRL receiver: builds the srtla_rec component (an SRTLA -> SRT forwarder)
# at a pinned SHA. The full OpenIRL management stack (srt-live-server + streamid
# auth) is intentionally omitted because it cannot forward to a plain SRT sink;
# the compat harness only exercises the SRTLA protocol path. See
# tests/compat/matrix.yaml notes for openirl-receiver.
# amd64 only.
ARG OPENIRL_SRTLA_REF=e9ba6a36ffaf179e92e06c7e3967637959fff363

FROM alpine:3.20 AS builder
ARG OPENIRL_SRTLA_REF
RUN apk add --no-cache linux-headers alpine-sdk cmake git spdlog spdlog-dev
WORKDIR /src
# Retry the network steps: CI has hit transient git exit-128 (clone/fetch) that
# a clean rerun resolves. find -mindepth 1 -delete clears a partial checkout
# between attempts without removing the WORKDIR itself.
RUN n=0; until git clone https://github.com/OpenIRL/srtla.git . ; do \
      n=$((n+1)); [ "$n" -ge 3 ] && { echo "clone failed after $n attempts" >&2; exit 1; }; \
      echo "git clone retry $n" >&2; find . -mindepth 1 -delete; sleep 5; \
    done \
 && git checkout "${OPENIRL_SRTLA_REF}" \
 && { git submodule update --init --recursive \
      || { sleep 5; git submodule update --init --recursive; }; } \
 && cmake -S . -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo \
 && cmake --build build --target srtla_rec -j"$(nproc)"

FROM alpine:3.20
# iproute2-ss provides `ss`, used by the compat harness to assert the UDP bind.
RUN apk add --no-cache libstdc++ spdlog iproute2-ss
COPY --from=builder /src/build/srtla_rec /usr/local/bin/srtla_rec
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh
ENV SRTLA_PORT=5000 \
    SRT_TARGET_HOST=127.0.0.1 \
    SRT_TARGET_PORT=4001
EXPOSE 5000/udp
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

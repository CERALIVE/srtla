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
RUN git clone https://github.com/OpenIRL/srtla.git . \
 && git checkout "${OPENIRL_SRTLA_REF}" \
 && git submodule update --init --recursive \
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

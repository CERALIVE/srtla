# BELABOX srtla reference receiver (srtla_rec), pinned by SHA.
# Same repository as the BELABOX sender; only the entrypoint differs.
# amd64 only.
ARG BELABOX_SRTLA_REF=6f3925eb85b0ce75d3b28e65b12e88baed222f71

FROM debian:bookworm-slim AS builder
ARG BELABOX_SRTLA_REF
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential git ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone https://github.com/BELABOX/srtla.git . \
 && git checkout "${BELABOX_SRTLA_REF}" \
 && make srtla_rec

FROM debian:bookworm-slim
# iproute2 provides `ss`, used by the compat harness to assert the UDP bind.
RUN apt-get update \
 && apt-get install -y --no-install-recommends iproute2 \
 && rm -rf /var/lib/apt/lists/*
COPY --from=builder /src/srtla_rec /usr/local/bin/srtla_rec
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh
ENV SRTLA_PORT=5000 \
    SRT_TARGET_HOST=127.0.0.1 \
    SRT_TARGET_PORT=4001
EXPOSE 5000/udp
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# go-irl receiver, pinned by SHA. amd64 only.
# Headless receiver-only mode is selected by the entrypoint via -mode=server.
#
# Build-fix (no source patch): go-irl embeds frontend/dist/index.html via
# //go:embed, but that file is a vite build artifact that is not committed to
# the repo, so `go build` fails on a clean checkout. Server mode never serves
# the browser source, so we stage a placeholder to satisfy the embed directive.
# See tests/compat/matrix.yaml notes for go-irl.
ARG GO_IRL_REF=fa9c1185182a1f59502e62e9fd6eb0fd8ad8c2d4

FROM golang:1.24-alpine AS builder
ARG GO_IRL_REF
RUN apk add --no-cache git
WORKDIR /src
RUN git clone https://github.com/e04/go-irl.git . \
 && git checkout "${GO_IRL_REF}" \
 && mkdir -p frontend/dist \
 && printf '<!doctype html><title>go-irl headless</title>' > frontend/dist/index.html
RUN CGO_ENABLED=0 go build -o /out/go-irl .

FROM alpine:3.20
# iproute2-ss provides `ss`, used by the compat harness to assert the UDP bind.
RUN apk add --no-cache iproute2-ss
COPY --from=builder /out/go-irl /usr/local/bin/go-irl
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh
ENV SRTLA_PORT=5000 \
    SRT_TARGET_HOST=127.0.0.1 \
    SRT_TARGET_PORT=4001
EXPOSE 5000/udp
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# go-srtla receiver (Go SRTLA -> SRT forwarder), pinned by SHA. amd64 only.
ARG GO_SRTLA_REF=8a3b55ba562891ddc6d272cb015e136035bbffc8

FROM golang:1.24-alpine AS builder
ARG GO_SRTLA_REF
RUN apk add --no-cache git
WORKDIR /src
RUN git clone https://github.com/e04/go-srtla.git . \
 && git checkout "${GO_SRTLA_REF}"
RUN CGO_ENABLED=0 go build -o /out/go-srtla .

FROM alpine:3.20
# iproute2-ss provides `ss`, used by the compat harness to assert the UDP bind.
RUN apk add --no-cache iproute2-ss
COPY --from=builder /out/go-srtla /usr/local/bin/go-srtla
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh
ENV SRTLA_PORT=5000 \
    SRT_TARGET_HOST=127.0.0.1 \
    SRT_TARGET_PORT=4001
EXPOSE 5000/udp
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

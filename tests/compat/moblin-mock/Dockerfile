# Moblin SRTLA conformance mock sender — compat test image.
#
# Unlike the other sender images, this one builds NOTHING from Moblin: per the
# task constraints there is no Swift compilation and the Moblin app is never run.
# The image ships a small Python re-implementation of Moblin's SRTLA *client*
# wire behaviour (moblin_mock.py), whose fidelity is documented and source-cited
# in BEHAVIOR.md (Moblin pinned at 0ae5294950166978064840bc874bfed3a8cf03a4 — the
# moblin-mock pin in tests/compat/matrix.yaml).
#
# Build (from this directory):
#   docker build --platform linux/amd64 -t compat/moblin-mock .
#
# Runtime env contract (shared with the other compat senders):
#   RECEIVER_HOST   target srtla_rec host           (default 127.0.0.1)
#   RECEIVER_PORT   target srtla_rec UDP port        (default 5000)
#   LOCAL_SRT_PORT  local UDP port the SRT feeder uses (default 6000)
#   IPS             source uplink IPs (first one is the mock's bind IP)

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY moblin_mock.py /usr/local/bin/moblin_mock.py
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/moblin_mock.py /entrypoint.sh

# Pre-generate a small loopable MPEG-TS test pattern used as the SRT source,
# exactly like the belabox/irlserver sender images.
RUN mkdir -p /assets \
    && ffmpeg -hide_banner -loglevel error \
        -f lavfi -i testsrc2=size=320x240:rate=25 -t 5 \
        -c:v mpeg2video -b:v 1M -f mpegts /assets/test.ts \
    && test -s /assets/test.ts

ENTRYPOINT ["/entrypoint.sh"]

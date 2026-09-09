# Pinned so the same source commit always builds the same image. Bumping this
# is a deliberate change, not something that happens on the next rebuild.
FROM alpine:3.22

# Install necessary packages
RUN apk add --no-cache \
    build-base \
    cmake \
    spdlog-dev \
    python3 \
    git

# Set the working directory \
WORKDIR /app

# Install argparse at the commit deps/argparse points at
RUN git clone https://github.com/p-ranav/argparse && \
    git -C argparse checkout -q 9550b0a88c85120a0bf456af935eed2956c73340 && \
    cd argparse && mkdir build && cd build && cmake .. && make install

# Copy the source code into the container
COPY . .

# Build the application
RUN mkdir build && cd build && \
    cmake .. && \
    make

EXPOSE 5000/udp
# The metrics endpoint binds to 127.0.0.1 by default, so it needs
# --metrics_bind :: to be reachable from outside the container.
EXPOSE 9997/tcp

# Both listening ports are non-privileged, so nothing here needs root.
RUN adduser -D -H -u 10001 srtla
USER srtla

# Set the entry point for the container
ENTRYPOINT ["./build/srtla_rec"]

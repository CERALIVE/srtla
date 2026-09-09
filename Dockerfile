FROM alpine:latest

# Install necessary packages
RUN apk add --no-cache \
    build-base \
    cmake \
    spdlog-dev \
    python3 \
    git

# Set the working directory \
WORKDIR /app

# Install argparse
RUN git clone https://github.com/p-ranav/argparse
RUN cd argparse && mkdir build && cd build && cmake .. && make install
RUN cd ../..

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

# Set the entry point for the container
ENTRYPOINT ["./build/srtla_rec"]

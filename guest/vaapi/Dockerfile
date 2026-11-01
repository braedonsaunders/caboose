# Build and test environment for the Caboose VA-API driver, on the guest's Debian 13:
# the C toolchain and the libraries the driver links, the encoders and reference
# decoders the round-trip tests compare against (ffmpeg), and Xvfb for a VA display.
#
#   docker build -t caboose-vaapi-dev guest/vaapi
#   guest/vaapi/scripts/dev.sh make check
FROM debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates build-essential pkg-config libva-dev libdrm-dev \
      libavcodec-dev libavutil-dev ffmpeg vainfo mesa-va-drivers python3 procps && \
    rm -rf /var/lib/apt/lists/*
RUN apt-get update && apt-get install -y --no-install-recommends xvfb libgl1-mesa-dri && \
    rm -rf /var/lib/apt/lists/*

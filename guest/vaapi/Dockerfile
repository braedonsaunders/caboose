# Build and test environment for the Caboose VA-API driver, on the guest's Debian 13:
# the C toolchain and the libraries the driver links, the reference decoders the
# round-trip tests compare against (ffmpeg), and the players the end-to-end checks
# drive (mpv, Chromium) on a headless Weston (GPU render node when given) or Xvfb.
#
#   docker build -t caboose-vaapi-dev guest/vaapi
#   guest/vaapi/scripts/dev.sh make check
FROM debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates build-essential pkg-config libva-dev libdrm-dev \
      libavcodec-dev libavutil-dev ffmpeg vainfo mesa-va-drivers python3 procps && \
    rm -rf /var/lib/apt/lists/*
RUN apt-get update && apt-get install -y --no-install-recommends \
      mpv chromium xvfb x11-utils xdotool imagemagick libgl1-mesa-dri mesa-utils \
      gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
      weston xwayland mesa-vulkan-drivers fonts-dejavu-core && \
    rm -rf /var/lib/apt/lists/*

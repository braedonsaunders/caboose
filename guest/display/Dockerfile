# Build and test environment for caboose-display, on the guest's Debian 13: the
# toolchain and libraries it links, plus the apps the scripted checks run against
# (weston-terminal, Chromium, X11 apps through Xwayland, ffmpeg).
#
#   docker build -t caboose-display-dev guest/display
#   guest/display/scripts/dev.sh cargo test
#
# The guest container image builds the release binary in its own stage
# (guest/container/Dockerfile).
FROM debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl build-essential pkg-config clang libclang-dev \
      libwayland-dev libxkbcommon-dev libudev-dev libgbm-dev libegl-dev libgles-dev libdrm-dev \
      libpixman-1-dev libavcodec-dev libavformat-dev libavutil-dev libswscale-dev libva-dev && \
    rm -rf /var/lib/apt/lists/*
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:$PATH
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain 1.95.0 \
      --component clippy,rustfmt && chmod -R a+rwX /opt/cargo /opt/rustup
RUN apt-get update && apt-get install -y --no-install-recommends \
      xwayland weston chromium x11-apps xterm ffmpeg mesa-utils libgl1-mesa-dri \
      mesa-va-drivers vainfo fonts-dejavu-core python3 procps && \
    rm -rf /var/lib/apt/lists/*
# Clipboard tools for the clipboard check (X11 and Wayland).
RUN apt-get update && apt-get install -y --no-install-recommends xclip wl-clipboard && \
    rm -rf /var/lib/apt/lists/*

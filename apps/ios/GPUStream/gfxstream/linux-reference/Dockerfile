FROM debian:trixie
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    build-essential cmake ninja-build git pkg-config python3 libvulkan-dev mesa-vulkan-drivers \
    libegl1-mesa-dev libgles2-mesa-dev libx11-dev libxext-dev libxrender-dev libxrandr-dev \
    libxi-dev libxfixes-dev libxdamage-dev libxcomposite-dev libxkbcommon-dev libwayland-dev \
    libdrm-dev libgbm-dev libglm-dev libepoxy-dev libprotobuf-dev protobuf-compiler \
    libabsl-dev libzstd-dev zlib1g-dev

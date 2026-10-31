# Build environment for the Caboose gfxstream Vulkan driver (libvulkan_gfxstream.so).
# The base image and every package are pinned: the Debian archive is read from a fixed
# snapshot, so the same inputs produce the same compiler, headers and library.
FROM debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad
ARG SNAPSHOT=20261030T000000Z
ENV DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 TZ=UTC
RUN rm -f /etc/apt/sources.list.d/debian.sources && \
    printf 'deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/%s trixie main\n' "$SNAPSHOT" \
      > /etc/apt/sources.list && \
    apt-get -o Acquire::Retries=5 update && \
    apt-get -o Acquire::Retries=5 install -y --no-install-recommends \
      g++ gcc binutils make meson ninja-build pkg-config git ca-certificates \
      python3 python3-mako python3-yaml python3-packaging \
      libdrm-dev libwayland-dev libxcb1-dev libx11-xcb-dev libexpat1-dev zlib1g-dev libzstd-dev && \
    rm -rf /var/lib/apt/lists/* && \
    mkdir -m 1777 /work

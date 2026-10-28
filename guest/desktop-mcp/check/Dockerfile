# Test bed for a11y.py: Debian 13 with the image's X, D-Bus, AT-SPI and app packages,
# Xpra 6.5.5 from its signed repository (as in the guest image; the arm64 build has its
# own package revision, hence the pin by upstream version), Mousepad and Chromium.
# Native architecture: builds on amd64 and arm64. Used by ../check-a11y.sh.
FROM debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && \
    curl -fsSL https://xpra.org/xpra.asc -o /usr/share/keyrings/xpra.asc && \
    curl -fsSL https://raw.githubusercontent.com/Xpra-org/xpra/v6.5.5/packaging/repos/trixie/xpra.sources -o /etc/apt/sources.list.d/xpra.sources && \
    printf 'Package: xpra xpra-*\nPin: version 6.5.5-*\nPin-Priority: 1001\n' > /etc/apt/preferences.d/xpra && \
    apt-get update && apt-get install -y --no-install-recommends \
      xvfb xauth x11-utils xdotool wmctrl imagemagick dbus dbus-x11 at-spi2-core \
      python3 python3-gi python3-pyatspi gir1.2-gtk-3.0 gsettings-desktop-schemas \
      libglib2.0-bin mousepad chromium nodejs fonts-dejavu-core procps \
      xpra xpra-server xpra-x11 xpra-common && \
    rm -rf /var/lib/apt/lists/* && \
    useradd -m -u 1000 -s /bin/bash caboose
CMD ["sleep", "infinity"]

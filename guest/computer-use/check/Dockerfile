# Test bed for the caboose-computer-use packages: Debian 13 with the image's X, D-Bus, AT-SPI
# and app packages, Mousepad and Chromium, and Caboose Display built from this checkout for
# the owner's display and the agent seat. Native architecture: builds on amd64 and arm64.
# Built with guest/ as the context by ../check-a11y.sh.
FROM debian@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4 AS display
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl build-essential pkg-config clang libclang-dev \
      libwayland-dev libxcb1-dev libxkbcommon-dev libudev-dev libpixman-1-dev libgbm-dev \
      libavcodec-dev libavformat-dev libavutil-dev libswscale-dev libva-dev libdrm-dev && \
    rm -rf /var/lib/apt/lists/*
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:$PATH
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain 1.95.0
COPY display /src
RUN cd /src && CARGO_BUILD_JOBS=2 cargo build --release --locked -p caboose-display -p caboose-display-probe

FROM debian@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      xvfb xwayland libegl1 libgl1-mesa-dri xauth x11-utils xdotool wmctrl imagemagick dbus dbus-x11 at-spi2-core \
      python3 python3-gi python3-pyatspi gir1.2-gtk-3.0 gsettings-desktop-schemas \
      libglib2.0-bin mousepad chromium nodejs fonts-dejavu-core procps sudo libxres1 gir1.2-gdkpixbuf-2.0 tesseract-ocr tesseract-ocr-eng \
      libpixman-1-0 libxkbcommon0 libavcodec61 libavformat61 libavutil59 libswscale8 libgbm1 mesa-vulkan-drivers xdg-desktop-portal-gtk ca-certificates && \
    printf 'deb https://deb.debian.org/debian trixie-backports main\n' > /etc/apt/sources.list.d/trixie-backports.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends -t trixie-backports $(dpkg-query -W -f '${db:Status-Status} ${Package}\n' \
      at-spi2-core at-spi2-common libatspi2.0-0t64 gir1.2-atspi-2.0 libatk-adaptor libatk-bridge2.0-0t64 libatk1.0-0t64 \
      gir1.2-atk-1.0 2>/dev/null | awk '$1 == "installed" { print $2 }') && \
    rm -rf /var/lib/apt/lists/* && \
    useradd -m -u 1000 -s /bin/bash caboose
COPY --from=display /src/target/release/caboose-display /src/target/release/caboose-display-probe /usr/local/bin/
CMD ["sleep", "infinity"]

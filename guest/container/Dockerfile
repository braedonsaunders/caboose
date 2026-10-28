# Caboose Display (guest/display): built here so the image carries it; Xpra stays
# the default display until the host selects caboose-display.
FROM debian:trixie-slim AS display
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl build-essential pkg-config clang libclang-dev \
      libwayland-dev libxkbcommon-dev libudev-dev libpixman-1-dev \
      libavcodec-dev libavformat-dev libavutil-dev libswscale-dev libva-dev libdrm-dev && \
    rm -rf /var/lib/apt/lists/*
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:$PATH
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain 1.95.0
COPY display /src
RUN cd /src && cargo build --release --locked -p caboose-display -p caboose-display-probe
# The codec passthrough VA-API driver (guest/vaapi): only used in Caboose Display sessions.
COPY vaapi /vaapi
RUN make -C /vaapi BUILD=/out/vaapi /out/vaapi/caboose_drv_video.so

FROM debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive
# This disposable image build can safely skip per-package fsync on WSL's HDD.
RUN echo force-unsafe-io > /etc/dpkg/dpkg.cfg.d/02unsafe-io && \
    echo 'Acquire::http::Pipeline-Depth 8;' > /etc/apt/apt.conf.d/90fast && \
    apt-get update && apt-get install -y --no-install-recommends eatmydata ca-certificates curl gnupg
ENV LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libeatmydata.so.1
RUN printf 'deb https://deb.debian.org/debian trixie main contrib non-free non-free-firmware\ndeb https://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware\n' > /etc/apt/sources.list && \
    curl -fsSL https://xpra.org/xpra.asc -o /usr/share/keyrings/xpra.asc && \
    curl -fsSL https://raw.githubusercontent.com/Xpra-org/xpra/v6.5.5/packaging/repos/trixie/xpra.sources -o /etc/apt/sources.list.d/xpra.sources && \
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft.gpg && \
    printf 'deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main\n' > /etc/apt/sources.list.d/vscode.list && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg && \
    printf 'deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main\n' > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && apt-get install -y --no-install-recommends \
      sudo systemd dbus dbus-user-session dbus-x11 xauth xvfb xwayland x11-utils xdotool wmctrl xclip \
      python3 python3-gi gir1.2-gtk-3.0 python3-pyatspi python3-websockets \
      libglib2.0-bin libglib2.0-dev-bin imagemagick ffmpeg at-spi2-core gsettings-desktop-schemas xfce4-settings \
      code nodejs sassc libxml2-utils qt5-gtk-platformtheme qt6-gtk-platformtheme \
      libgl1-mesa-dri mesa-va-drivers mesa-utils vainfo libx264-164 \
      pulseaudio pulseaudio-utils gstreamer1.0-plugins-good gstreamer1.0-pulseaudio gstreamer1.0-tools \
      python3-numpy python3-pytools python3-mako python3-decorator python3-platformdirs \
      libboost-python1.83.0 libboost-thread1.83.0 libcurand10 \
      xpra=6.5.5-r0-1 xpra-server=6.5.5-r0-1 xpra-x11=6.5.5-r0-1 xpra-common=6.5.5-r0-1 \
      xpra-codecs=6.5.5-r0-1 xpra-codecs-extras=6.5.5-r0-1 xpra-codecs-nvidia=6.5.5-r0-1 xpra-audio=6.5.5-r0-1 && \
    cd /tmp && apt-get download python3-pycuda && dpkg-deb -x python3-pycuda_*.deb / && rm python3-pycuda_*.deb && \
    useradd -m -u 1000 -s /bin/bash caboose && usermod -aG sudo caboose && \
    printf 'caboose ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/caboose && chmod 0440 /etc/sudoers.d/caboose
COPY image/apps.sh /tmp/caboose-apps.sh
RUN bash /tmp/caboose-apps.sh
COPY desktop-mcp /tmp/desktop-mcp
RUN /tmp/desktop-mcp/install.sh
COPY agentd/caboose-agentd.mjs agentd/package.json agentd/install.sh /tmp/agentd/
RUN /tmp/agentd/install.sh && rm -rf /tmp/agentd
COPY media-handoff /tmp/media-handoff
RUN /tmp/media-handoff/install.sh && rm -rf /tmp/media-handoff
RUN export USER=root HOME=/root TERM=xterm && mkdir -p /tmp/themes && \
    for spec in 'WhiteSur-gtk-theme d5782652d412137e26fb8ff55b55a5572e4c6995' 'WhiteSur-icon-theme 73d8040da51a9ed74e47c7366e7e9ff437601a5c' 'WhiteSur-cursors e190baf618ed95ee217d2fd45589bd309b37672b'; do \
      set -- $spec; git clone -q "https://github.com/vinceliuice/$1.git" "/tmp/themes/$1" && git -C "/tmp/themes/$1" checkout -q "$2" || exit 1; \
    done && \
    /tmp/themes/WhiteSur-gtk-theme/install.sh -d /usr/share/themes -c dark && \
    /tmp/themes/WhiteSur-icon-theme/install.sh -d /usr/share/icons && \
    (cd /tmp/themes/WhiteSur-cursors && ./install.sh) && \
    mkdir -p /etc/xdg/gtk-3.0 /etc/chromium.d && \
    printf '[Settings]\ngtk-theme-name=WhiteSur-Dark\ngtk-icon-theme-name=WhiteSur-dark\ngtk-cursor-theme-name=WhiteSur-cursors\ngtk-font-name=Inter 10\ngtk-application-prefer-dark-theme=1\n' > /etc/xdg/gtk-3.0/settings.ini && \
    printf 'CHROMIUM_FLAGS="$CHROMIUM_FLAGS --ignore-gpu-blocklist --use-gl=angle --use-angle=gl"\n' > /etc/chromium.d/caboose-gpu && \
    rm -rf /tmp/themes /tmp/desktop-mcp /var/lib/apt/lists/*
RUN apt-get update && apt-get install -y --no-install-recommends chromium-sandbox && rm -rf /var/lib/apt/lists/*
COPY container/chromium-gpu /etc/chromium.d/caboose-gpu
COPY --from=display /src/target/release/caboose-display /src/target/release/caboose-display-probe /usr/local/bin/
COPY --from=display /out/vaapi/caboose_drv_video.so /usr/lib/x86_64-linux-gnu/dri/caboose_drv_video.so
COPY display/caboose-display-ready /usr/local/bin/caboose-display-ready
COPY container/caboose-session /usr/local/bin/caboose-session
COPY container/caboose-audio.sh /etc/profile.d/caboose-audio.sh
RUN chmod 0755 /usr/local/bin/caboose-session && \
    printf '\n[ -r /etc/profile.d/caboose-audio.sh ] && . /etc/profile.d/caboose-audio.sh\n' >> /etc/bash.bashrc
ENV LD_PRELOAD= CABOOSE_GPU=none DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus XPRA_BACKWARDS_COMPATIBLE=0 GDK_SCALE=1 QT_QPA_PLATFORMTHEME=gtk3 \
    ACCESSIBILITY_ENABLED=1 GNOME_ACCESSIBILITY=1 QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1
CMD ["sleep", "infinity"]

# Caboose Display (guest/display) and the Caboose VA-API driver (guest/vaapi), built for the guest.
FROM debian:trixie-slim AS display
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl build-essential pkg-config clang libclang-dev \
      libwayland-dev libxkbcommon-dev libudev-dev libavcodec-dev libavformat-dev libavutil-dev libva-dev libdrm-dev libgbm-dev && \
    rm -rf /var/lib/apt/lists/*
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:$PATH
RUN curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain 1.95.0
COPY display /src
ARG CARGO_BUILD_JOBS=2
RUN cd /src && cargo build --release --locked --jobs "$CARGO_BUILD_JOBS" -p caboose-display -p caboose-display-probe
COPY vaapi /vaapi
RUN make -C /vaapi BUILD=/out/vaapi /out/vaapi/caboose_drv_video.so
# The Win32 side of desktop MCP's Wine reader (guest/desktop-mcp/wine), cross-built here so no
# computer needs a Windows compiler.
RUN apt-get update && apt-get install -y --no-install-recommends gcc-mingw-w64-x86-64-win32 && rm -rf /var/lib/apt/lists/*
COPY desktop-mcp/wine /wine
RUN mkdir -p /out/wine && x86_64-w64-mingw32-gcc -O2 -municode -o /out/wine/caboose-msaa.exe /wine/caboose-msaa.c \
      -loleacc -loleaut32 -lole32 -luuid -luser32

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends debootstrap eatmydata util-linux fdisk e2fsprogs erofs-utils btrfs-progs ca-certificates curl && rm -rf /var/lib/apt/lists/*
COPY image/build-inside.sh image/configure-guest.sh image/apps.sh image/desktop-apps.sh image/desktop-apps.tsv image/make-system-image.sh image/storage-layout.sh /builder/
COPY image/initramfs/caboose-system image/initramfs/caboose-storage /builder/
COPY components /builder/components
COPY memory/install.sh memory/caboose-memory.py memory/caboose-memory.service /builder/components/memory/
COPY memory/install.sh memory/caboose-memory.py memory/caboose-memory.service /builder/memory/
COPY template/caboose-template.py template/caboose-template.target /builder/template/
COPY keyring /builder/keyring
COPY container/caboose-session /builder/container/
COPY files /builder/files
COPY terminal /builder/terminal
COPY ports /builder/ports
COPY desktop-mcp /builder/desktop-mcp
COPY --from=display /out/wine/caboose-msaa.exe /builder/desktop-mcp/wine/caboose-msaa.exe
COPY notifications /builder/notifications
COPY webmcp /builder/webmcp
COPY scopes /builder/scopes

COPY phone /builder/phone
COPY devices /builder/devices
COPY bridge /builder/bridge
COPY flatpak /builder/flatpak
COPY game /builder/game
COPY gpu /builder/gpu
COPY ai /builder/ai
COPY wine /builder/wine
COPY apps/install.sh apps/caboose-app apps/appcore.py apps/net.py apps/remote.py apps/page.js apps/world.js apps/guide.md apps/apps-mcp.mjs /builder/apps/
COPY --from=display /src/target/release/caboose-display /src/target/release/caboose-display-probe /out/vaapi/caboose_drv_video.so /builder/display/
COPY display/caboose-display-ready display/systemd/caboose-display.service display/systemd/caboose-display-agent.service /builder/display/
COPY agentd/caboose-agentd.mjs agentd/agent-tools.mjs agentd/library-mcp.mjs agentd/package.json agentd/install.sh /builder/agentd/
ENTRYPOINT ["/builder/build-inside.sh"]

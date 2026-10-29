# Caboose Display (guest/display) and the VA-API passthrough driver (guest/vaapi), built for the guest.
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
ARG CARGO_BUILD_JOBS=2
RUN cd /src && cargo build --release --locked --jobs "$CARGO_BUILD_JOBS" -p caboose-display -p caboose-display-probe
COPY vaapi /vaapi
RUN make -C /vaapi BUILD=/out/vaapi /out/vaapi/caboose_drv_video.so

# The GPU stream driver and layers (guest/gpu), at the commits of one Vulkan SDK release.
FROM debian:trixie-slim AS gpu
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates git cmake ninja-build g++ python3 python3-venv libpython3-dev pkg-config \
      libx11-dev libx11-xcb-dev libxcb1-dev libxcb-keysyms1-dev libxrandr-dev libwayland-dev wayland-protocols && \
    rm -rf /var/lib/apt/lists/*
COPY gpu /gpu
ARG GPU_BUILD_JOBS=2
RUN CABOOSE_GPU_JOBS="$GPU_BUILD_JOBS" /gpu/build.sh /out/caboose-gpu

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends debootstrap eatmydata util-linux fdisk e2fsprogs ca-certificates curl && rm -rf /var/lib/apt/lists/*
COPY image/build-inside.sh image/configure-guest.sh image/apps.sh image/desktop-apps.sh image/desktop-apps.tsv /builder/
COPY components /builder/components
COPY files /builder/files
COPY terminal /builder/terminal
COPY desktop-mcp /builder/desktop-mcp
COPY notifications /builder/notifications

COPY phone /builder/phone
COPY bridge /builder/bridge
COPY flatpak /builder/flatpak
COPY game /builder/game
COPY gpu /builder/gpu
COPY apps/install.sh apps/caboose-app apps/appcore.py apps/page.js apps/world.js apps/guide.md apps/apps-mcp.mjs /builder/apps/
COPY --from=display /src/target/release/caboose-display /src/target/release/caboose-display-probe /out/vaapi/caboose_drv_video.so /builder/display/
COPY --from=gpu /out/caboose-gpu /builder/display/caboose-gpu
COPY display/caboose-display-ready display/systemd/caboose-display.service display/systemd/caboose-display-agent.service /builder/display/
COPY agentd/caboose-agentd.mjs agentd/agent-tools.mjs agentd/library-mcp.mjs agentd/package.json agentd/install.sh /builder/agentd/
ENTRYPOINT ["/builder/build-inside.sh"]

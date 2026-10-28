# Caboose Display (guest/display), built for the guest; installed but not enabled.
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
COPY vaapi /vaapi
RUN make -C /vaapi BUILD=/out/vaapi /out/vaapi/caboose_drv_video.so

FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends debootstrap eatmydata util-linux fdisk e2fsprogs ca-certificates curl && rm -rf /var/lib/apt/lists/*
COPY image/build-inside.sh image/configure-guest.sh image/apps.sh image/caboose-xpra.service image/caboose-xpra-agent.service /builder/
COPY files /builder/files
COPY desktop-mcp /builder/desktop-mcp
COPY phone /builder/phone
COPY --from=display /src/target/release/caboose-display /src/target/release/caboose-display-probe /out/vaapi/caboose_drv_video.so /builder/display/
COPY display/caboose-display-ready display/systemd/caboose-display.service /builder/display/
COPY agentd/caboose-agentd.mjs agentd/package.json agentd/install.sh /builder/agentd/
ENTRYPOINT ["/builder/build-inside.sh"]

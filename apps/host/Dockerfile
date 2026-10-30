FROM node:22-bookworm-slim AS build-deps
WORKDIR /src
RUN corepack enable
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY apps/host/package.json apps/host/package.json
COPY apps/web/package.json apps/web/package.json
COPY guest/agentd/package.json guest/agentd/package.json
RUN pnpm install --frozen-lockfile

FROM build-deps AS host-build
COPY apps/host/tsconfig.json apps/host/tsconfig.json
COPY apps/host/src apps/host/src
RUN pnpm --filter caboose-host exec tsc --outDir dist && \
    cp apps/host/src/*.py apps/host/dist/

FROM build-deps AS web-build
COPY apps/web apps/web
RUN pnpm --filter caboose-web build

# Keep browser dependencies and build tooling out of the running host.
FROM node:22-bookworm-slim AS host-deps
WORKDIR /src
RUN corepack enable
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY apps/host/package.json apps/host/package.json
RUN pnpm --filter caboose-host... install --prod --frozen-lockfile

FROM debian:bookworm-slim AS vmm
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/*
ARG TARGETARCH
RUN case "$TARGETARCH" in \
      amd64) asset=desk-vmm-amd64.tar.gz; digest=f93fd7128779b57ac6fecb4e42e7d9a2e6ae5a3e88caea84a6c86879b08e6818 ;; \
      arm64) asset=desk-vmm-arm64.tar.gz; digest=9fdce8ded9dff25c8c35183995fd979ca509878862d421adc60232b5f7cfd1f7 ;; \
      *) exit 1 ;; esac && \
    curl -fsSL -o /desk-vmm.tar.gz "https://github.com/braedonsaunders/appkit/releases/download/desk-vmm-v54.0-incremental.1/$asset" && \
    echo "$digest  /desk-vmm.tar.gz" | sha256sum -c - && mkdir /desk-vmm && \
    tar -xzf /desk-vmm.tar.gz -C /desk-vmm && cd /desk-vmm && sha256sum -c SHA256SUMS && \
    chmod 0755 cloud-hypervisor ch-remote

# caboose-disk: shared storage and backup manifests (apps/host/disk).
FROM rust:1.94-slim-bookworm AS disk
WORKDIR /src
COPY apps/host/disk ./
RUN cargo build --release --locked && cp target/release/caboose-disk /caboose-disk

FROM node:22-bookworm-slim
ARG TARGETARCH
RUN case "$TARGETARCH" in amd64) kernel=linux-image-amd64; qemu=qemu-system-x86 ;; arm64) kernel=linux-image-arm64; qemu=qemu-system-arm ;; *) exit 1 ;; esac && \
    apt-get update && apt-get install -y --no-install-recommends iproute2 iptables procps qemu-utils xfsprogs util-linux python3 python3-guestfs erofs-utils btrfs-progs attr guestfish supermin "$qemu" "$kernel" && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=vmm /desk-vmm /usr/local/lib/desk-vmm
RUN ln -s /usr/local/lib/desk-vmm/cloud-hypervisor /usr/local/bin/cloud-hypervisor
COPY --from=disk /caboose-disk /usr/local/bin/caboose-disk
COPY --from=host-deps /src/node_modules ./node_modules
COPY --from=host-deps /src/apps/host/node_modules ./apps/host/node_modules
COPY --from=host-deps /src/apps/host/package.json ./apps/host/package.json
COPY --from=host-build /src/apps/host/dist ./apps/host/dist
# The identity database's own migrations, beside AppKit's in node_modules.
COPY apps/host/migrations ./apps/host/migrations
COPY apps/host/scripts/recover-template-source.sh ./apps/host/scripts/recover-template-source.sh
COPY guest/agentd/caboose-agentd.mjs guest/agentd/agent-tools.mjs guest/agentd/library-mcp.mjs guest/agentd/package.json guest/agentd/install.sh ./guest/agentd/
COPY guest/components ./guest/components
COPY guest/template/caboose-template.py guest/template/caboose-template.target ./guest/template/
COPY guest/desktop-mcp ./guest/desktop-mcp
COPY guest/keyring ./guest/keyring
COPY guest/container/caboose-session ./guest/container/
COPY guest/files ./guest/files
COPY guest/phone ./guest/phone
COPY guest/devices ./guest/devices
COPY guest/notifications ./guest/notifications
COPY guest/terminal ./guest/terminal
COPY guest/bridge ./guest/bridge
COPY guest/flatpak ./guest/flatpak
COPY guest/game ./guest/game
COPY guest/gpu/install.sh guest/gpu/caboose-gpu-run guest/gpu/profile.json ./guest/gpu/
COPY guest/apps/install.sh guest/apps/caboose-app guest/apps/appcore.py guest/apps/net.py guest/apps/remote.py guest/apps/page.js guest/apps/world.js guest/apps/guide.md guest/apps/apps-mcp.mjs ./guest/apps/
COPY guest/container/caboose-seccomp.json ./guest/container/caboose-seccomp.json
COPY guest/catalog/catalog.json ./guest/catalog/catalog.json
COPY guest/catalog/icons ./guest/catalog/icons
COPY --from=web-build /src/apps/web/dist ./apps/web/dist
COPY apps/host/scripts/migrate-disk.py ./apps/host/scripts/
COPY apps/host/src/migration_transaction.py apps/host/src/migration_appliance.py apps/host/src/migration_appliance_guard.py ./apps/host/src/
COPY guest/image/initramfs/caboose-system ./guest/image/initramfs/
COPY apps/host/scripts/setup-disks.sh /usr/local/bin/setup-disks
COPY apps/host/scripts/container-entrypoint.sh /usr/local/bin/caboose-entrypoint
ENV CABOOSE_IMAGE_ROOT=/data/caboose/disks CABOOSE_BIND=0.0.0.0
# A release pins the computer images it was built with (.github/workflows/release.yml); the host
# fetches the one its runtime needs on first run. A local build leaves both to the operator.
ARG CABOOSE_BASE_IMAGE=
ARG CABOOSE_CONTAINER_IMAGE=caboose-computer:latest
ARG CABOOSE_VERSION=
ENV CABOOSE_BASE_IMAGE=${CABOOSE_BASE_IMAGE} CABOOSE_CONTAINER_IMAGE=${CABOOSE_CONTAINER_IMAGE} CABOOSE_VERSION=${CABOOSE_VERSION}
ENTRYPOINT ["/usr/local/bin/caboose-entrypoint"]
CMD ["node", "apps/host/dist/index.js"]

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
    cp apps/host/src/guest-apps.py apps/host/src/guest-catalog.py apps/host/src/guest-store.py apps/host/src/guest-craft.py apps/host/src/depot-builder.py apps/host/dist/

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
      amd64) asset=cloud-hypervisor-static; digest=4f4f98a3d661a40f3e5272627cc895a1b2e525f2f6bedf5f895f9cd21ba5c65b ;; \
      arm64) asset=cloud-hypervisor-static-aarch64; digest=e8a6d9786ea678e739f1a386682846e93742dcb9c7b6e3e0c62e3bda6cff0ef3 ;; \
      *) exit 1 ;; esac && \
    curl -fsSL -o /cloud-hypervisor "https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v54.0/$asset" && \
    echo "$digest  /cloud-hypervisor" | sha256sum -c - && chmod 0755 /cloud-hypervisor

FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends iproute2 iptables procps qemu-utils xfsprogs util-linux && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=vmm /cloud-hypervisor /usr/local/bin/cloud-hypervisor
COPY --from=host-deps /src/node_modules ./node_modules
COPY --from=host-deps /src/apps/host/node_modules ./apps/host/node_modules
COPY --from=host-deps /src/apps/host/package.json ./apps/host/package.json
COPY --from=host-build /src/apps/host/dist ./apps/host/dist
# The identity database's own migrations, beside AppKit's in node_modules.
COPY apps/host/migrations ./apps/host/migrations
COPY guest/agentd/caboose-agentd.mjs guest/agentd/agent-tools.mjs guest/agentd/package.json guest/agentd/install.sh ./guest/agentd/
COPY guest/components ./guest/components
COPY guest/files ./guest/files
COPY guest/phone ./guest/phone
COPY guest/notifications ./guest/notifications
COPY guest/terminal ./guest/terminal
COPY guest/bridge ./guest/bridge
COPY guest/flatpak ./guest/flatpak
COPY guest/game ./guest/game
COPY guest/gpu/install.sh guest/gpu/caboose-gpu-run guest/gpu/profile.json ./guest/gpu/
COPY guest/apps/install.sh guest/apps/caboose-app guest/apps/appcore.py guest/apps/page.js guest/apps/world.js guest/apps/guide.md guest/apps/apps-mcp.mjs ./guest/apps/
COPY guest/container/caboose-seccomp.json ./guest/container/caboose-seccomp.json
COPY guest/catalog/catalog.json ./guest/catalog/catalog.json
COPY guest/catalog/icons ./guest/catalog/icons
COPY --from=web-build /src/apps/web/dist ./apps/web/dist
COPY apps/host/scripts/setup-disks.sh /usr/local/bin/setup-disks
COPY apps/host/scripts/container-entrypoint.sh /usr/local/bin/caboose-entrypoint
ENV CABOOSE_IMAGE_ROOT=/data/caboose/disks CABOOSE_BIND=0.0.0.0
# A release pins the computer images it was built with (.github/workflows/release.yml); the host
# fetches the one its runtime needs on first run. A local build leaves both to the operator.
ARG CABOOSE_BASE_IMAGE=
ARG CABOOSE_CONTAINER_IMAGE=caboose-computer:latest
ENV CABOOSE_BASE_IMAGE=${CABOOSE_BASE_IMAGE} CABOOSE_CONTAINER_IMAGE=${CABOOSE_CONTAINER_IMAGE}
ENTRYPOINT ["/usr/local/bin/caboose-entrypoint"]
CMD ["node", "apps/host/dist/index.js"]

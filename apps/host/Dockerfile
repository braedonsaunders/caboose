FROM node:22-bookworm-slim AS build
WORKDIR /src
RUN corepack enable
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY apps/host/package.json apps/host/package.json
RUN pnpm install --frozen-lockfile
COPY apps/host/tsconfig.json apps/host/tsconfig.json
COPY apps/host/src apps/host/src
RUN pnpm --filter caboose-host exec tsc --outDir dist && \
    cp apps/host/src/guest-apps.py apps/host/dist/ && \
    rm -rf node_modules apps/host/node_modules && \
    pnpm install --prod --frozen-lockfile

FROM debian:bookworm-slim AS vmm
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /cloud-hypervisor https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/v54.0/cloud-hypervisor-static && \
    echo '4f4f98a3d661a40f3e5272627cc895a1b2e525f2f6bedf5f895f9cd21ba5c65b  /cloud-hypervisor' | sha256sum -c - && chmod 0755 /cloud-hypervisor

FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends iproute2 iptables procps qemu-utils xfsprogs util-linux && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=vmm /cloud-hypervisor /usr/local/bin/cloud-hypervisor
COPY --from=build /src/node_modules ./node_modules
COPY --from=build /src/apps/host/node_modules ./apps/host/node_modules
COPY --from=build /src/apps/host/package.json ./apps/host/package.json
COPY --from=build /src/apps/host/dist ./apps/host/dist
COPY apps/host/scripts/setup-disks.sh /usr/local/bin/setup-disks
COPY apps/host/scripts/container-entrypoint.sh /usr/local/bin/caboose-entrypoint
ENV CABOOSE_IMAGE_ROOT=/data/caboose/disks CABOOSE_BIND=0.0.0.0
ENTRYPOINT ["/usr/local/bin/caboose-entrypoint"]
CMD ["node", "apps/host/dist/index.js"]

# The Caboose WSL distribution: Debian 13 with systemd, Docker Engine and caboose-host.
# build.sh builds it for linux/amd64 and exports the filesystem as a rootfs for `wsl --import`;
# it is never run as a container image itself.

# The caboose-host bundle, unpacked to /opt/caboose/<version> with /opt/caboose/current.
FROM debian:trixie-slim AS bundle
RUN apt-get update && apt-get install -y --no-install-recommends zstd && rm -rf /var/lib/apt/lists/*
COPY caboose-host.tar.zst /tmp/bundle.tar.zst
RUN set -eu; \
    mkdir -p /tmp/unpack /opt/caboose; \
    zstd -dc /tmp/bundle.tar.zst | tar -xf - -C /tmp/unpack; \
    src=/tmp/unpack/caboose-host; \
    [ -x "$src/bin/caboose-host" ] || { echo "the bundle has no caboose-host/bin/caboose-host" >&2; exit 1; }; \
    version=$(head -n1 "$src/VERSION"); \
    case "$version" in ''|*[!A-Za-z0-9._+-]*) echo "unusable bundle VERSION: '$version'" >&2; exit 1 ;; esac; \
    mv "$src" "/opt/caboose/$version"; \
    ln -s "$version" /opt/caboose/current

# Docker's apt signing key, checked against its published fingerprint.
FROM debian:trixie-slim AS docker-key
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gnupg && rm -rf /var/lib/apt/lists/*
RUN set -eu; \
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /docker.asc; \
    gpg --show-keys --with-colons /docker.asc | grep -q '^fpr:::::::::9DC858229FC7DD38854AE2D88D81803C0EBFCD88:$'

FROM debian:trixie
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus ca-certificates curl iproute2 iptables procps kmod \
      zstd xz-utils less unattended-upgrades \
    && rm -rf /var/lib/apt/lists/*
COPY --from=docker-key /docker.asc /etc/apt/keyrings/docker.asc
RUN printf '%s\n' 'Types: deb' 'URIs: https://download.docker.com/linux/debian' 'Suites: trixie' \
      'Components: stable' 'Architectures: amd64' 'Signed-By: /etc/apt/keyrings/docker.asc' \
      >/etc/apt/sources.list.d/docker.sources \
    && apt-get update && apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io \
    && rm -rf /var/lib/apt/lists/*

COPY rootfs/ /
COPY --from=bundle /opt/caboose /opt/caboose

# The computer image this release runs; releases pass one pinned by digest.
ARG CABOOSE_CONTAINER_IMAGE=ghcr.io/braedonsaunders/caboose-computer:latest
RUN set -eu; \
    case "$CABOOSE_CONTAINER_IMAGE" in ''|*[!A-Za-z0-9./:@_-]*) echo "unusable CABOOSE_CONTAINER_IMAGE" >&2; exit 1 ;; esac; \
    sed -i "s|@CABOOSE_CONTAINER_IMAGE@|$CABOOSE_CONTAINER_IMAGE|" /usr/lib/systemd/system/caboose-host.service; \
    chmod 0755 /usr/local/bin/caboose-wsl-ready /usr/local/bin/caboose-keepalive /usr/lib/caboose/caboose-upgrade; \
    chmod 0600 /etc/caboose/host.env; \
    ln -s /opt/caboose/current/bin/caboose-host /usr/local/bin/caboose-host; \
    systemctl enable caboose-host.service docker.service containerd.service; \
    # WSL has no console to answer first-boot prompts, and no hardware for these units.
    systemctl mask systemd-firstboot.service getty@tty1.service serial-getty@ttyS0.service \
      systemd-networkd-wait-online.service; \
    # A machine id of its own on first boot, never the build's.
    : >/etc/machine-id; rm -f /var/lib/dbus/machine-id; \
    install -d -m 0700 /var/lib/caboose

#!/usr/bin/env bash
# Run on the native Linux amd64 release runner with Docker.
set -euo pipefail
out=${1:?usage: build-rootfs.sh output-directory}
mkdir -p "$out"
work=$(mktemp -d)
container=
trap '[[ -z $container ]] || docker rm "$container" >/dev/null; rm -rf "$work"' EXIT
cat > "$work/Dockerfile" <<'DOCKER'
FROM debian:13-slim
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends systemd systemd-sysv dbus docker.io curl ca-certificates zstd iproute2 iptables util-linux qrencode && rm -rf /var/lib/apt/lists/*
RUN printf '[boot]\nsystemd=true\n[user]\ndefault=root\n' > /etc/wsl.conf && systemctl enable docker && truncate -s 0 /etc/machine-id
DOCKER
docker build --platform linux/amd64 -t caboose-wsl-rootfs "$work"
container=$(docker create caboose-wsl-rootfs)
docker export "$container" | gzip -n > "$out/caboose-wsl-rootfs-amd64.tar.gz"
(cd "$out" && sha256sum caboose-wsl-rootfs-amd64.tar.gz > caboose-wsl-rootfs-amd64.tar.gz.sha256)

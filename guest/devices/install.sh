#!/bin/bash
# Prepares a computer for the phone's hardware (docs/devices.md): the kernel modules, udev
# rules for the device nodes, v4l2loopback built for the kernel with DKMS, and
# iio-sensor-proxy for the IIO sensors. A container computer uses its host's kernel, so it
# needs none of this.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
mode=${1:?expected image-vm, image-container, vm or container}
case "$mode" in
  image-container|container) exit 0 ;;
  image-vm|vm) ;;
  *) exit 2 ;;
esac
export DEBIAN_FRONTEND=noninteractive
install -Dm644 "$here/70-caboose-devices.rules" /etc/udev/rules.d/70-caboose-devices.rules
printf 'uinput\nuhid\nv4l2loopback\n' > /etc/modules-load.d/caboose-devices.conf
# No loopback devices at load: the owner's display adds one per camera the phone offers.
printf 'options v4l2loopback devices=0\n' > /etc/modprobe.d/caboose-v4l2loopback.conf
usermod -aG video caboose

installed() { [ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || :)" = installed ]; }
apt_install() {
  local log
  log=$(mktemp /tmp/caboose-apt.XXXXXXXX)
  if ! apt-get update >"$log" 2>&1 || ! apt-get install -y --no-install-recommends "$@" >>"$log" 2>&1; then
    tail -n 80 "$log" >&2
    rm -f "$log"
    return 1
  fi
  rm -f "$log"
}

packages=()
installed iio-sensor-proxy || packages+=(iio-sensor-proxy)
if [ "$mode" = image-vm ]; then
  # The image's kernel: DKMS builds v4l2loopback for it while installing.
  arch=$(dpkg --print-architecture)
  installed v4l2loopback-dkms || packages+=(v4l2loopback-dkms "linux-headers-$arch")
elif ! modinfo v4l2loopback >/dev/null 2>&1 && modinfo videodev >/dev/null 2>&1; then
  # A running computer builds it for its own kernel when Debian still has that kernel's
  # headers; otherwise its cameras stay unavailable and say so.
  if apt-cache show "linux-headers-$(uname -r)" >/dev/null 2>&1; then
    packages+=(v4l2loopback-dkms "linux-headers-$(uname -r)")
  fi
fi
if ((${#packages[@]})); then
  apt_install "${packages[@]}"
fi

if [ "$mode" = vm ]; then
  udevadm control --reload
  for module in uinput uhid v4l2loopback; do modprobe "$module" 2>/dev/null || :; done
  udevadm trigger --subsystem-match=misc --subsystem-match=input --action=change
fi

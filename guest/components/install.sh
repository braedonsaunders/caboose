#!/bin/bash
# Install Caboose's own guest plumbing. The bundle is rooted at the parent of this file.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mode=${1:?expected image-vm, image-container, vm or container}
case "$mode" in image-vm|image-container|vm|container) ;; *) exit 2;; esac
export DEBIAN_FRONTEND=noninteractive
packages=(gnome-keyring appstream gir1.2-appstream-1.0 cups cups-filters desktop-file-utils xdg-utils libnotify-bin python3-gi gir1.2-gtk-3.0 python3-websockets dbus-user-session libgl1-mesa-dri mesa-vulkan-drivers libgl1 libvulkan1 libxcb-keysyms1 xdg-desktop-portal xdg-desktop-portal-gtk geoclue-2.0 flatpak gir1.2-flatpak-1.0 gir1.2-webkit2-4.1 curl)
# Steam's native amd64 client still launches a 32-bit reaper and overlay outside
# its bundled runtime. Keep their host loader/GL dependencies available to all
# titles. Debian's amd64 libc6-i386 supplies /lib/ld-linux.so.2; libgl1:i386
# supplies the overlay's GL dependency and its normal APT dependency closure.
if [[ $(dpkg --print-architecture) = amd64 ]]; then
  foreign_architectures=$(dpkg --print-foreign-architectures)
  if [[ $'\n'"$foreign_architectures"$'\n' != *$'\ni386\n'* ]]; then
    dpkg --add-architecture i386
  fi
  packages+=(libc6-i386 libgl1:i386)
fi
missing=()
for pkg in "${packages[@]}"; do
  [ "$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || :)" = installed ] || missing+=("$pkg")
done
# NodeSource's nodejs includes npm without a separate Debian npm package. Check the
# commands themselves, and let a newly installed nodejs supply npm before asking APT.
node --version >/dev/null 2>&1 || missing+=(nodejs)
install_packages() {
  (($#)) || return 0
  log=$(mktemp /tmp/caboose-apt.XXXXXXXX)
  trap 'rm -f "$log"' EXIT
  if ! dpkg --configure -a >"$log" 2>&1 || ! apt-get update >>"$log" 2>&1 || ! apt-get install -y --no-install-recommends "$@" >>"$log" 2>&1; then
    tail -n 80 "$log" >&2
    exit 1
  fi
  rm -f "$log"
  trap - EXIT
}
if ((${#missing[@]})); then
  install_packages "${missing[@]}"
  # AppStream installs APT index targets; fetch them after installing its configuration.
  if [[ " ${missing[*]} " == *" appstream "* ]]; then
    apt-get update
  fi
fi
npm --version >/dev/null 2>&1 || install_packages npm
if ! node --version >/dev/null 2>&1 || ! npm --version >/dev/null 2>&1; then
  echo 'Guest components require working node and npm commands after package installation' >&2
  exit 1
fi
install -Dm644 "$root/files/event_stream.py" /opt/caboose/files/event_stream.py
install -Dm755 "$root/files/caboose-files.py" /opt/caboose/files/caboose-files.py
install -Dm755 "$root/components/check-steam-bootstrap.sh" /usr/local/libexec/caboose-check-steam-bootstrap
install -Dm755 "$root/files/parked_quiesce.py" /opt/caboose/files/parked_quiesce.py
install -Dm644 "$root/files/caboose-files.service" /etc/systemd/system/caboose-files.service
install -Dm755 "$root/terminal/caboose-terminal.py" /opt/caboose/terminal/caboose-terminal.py
install -Dm644 "$root/terminal/caboose-terminal.service" /etc/systemd/system/caboose-terminal.service
install -Dm755 "$root/desktop-mcp/caboose-desktop-mcp.mjs" /opt/caboose/desktop-mcp.mjs
install -Dm755 "$root/desktop-mcp/a11y.py" /opt/caboose/a11y.py
install -Dm755 "$root/desktop-mcp/seat.py" /opt/caboose/seat.py
install -Dm644 "$root/desktop-mcp/ensure-agent-seat.mjs" /opt/caboose/ensure-agent-seat.mjs
install -Dm644 "$root/desktop-mcp/ensure-agent-seat.mjs" /opt/caboose/desktop-mcp/ensure-agent-seat.mjs
install -Dm755 "$root/desktop-mcp/caboose-agent-seat" /usr/local/libexec/caboose-agent-seat
sh "$root/keyring/install.sh"
sh "$root/notifications/install.sh"
bash "$root/phone/install.sh"
sh "$root/bridge/install.sh"
sh "$root/flatpak/install.sh" "$mode"
sh "$root/game/install.sh"
sh "$root/gpu/install.sh"
sh "$root/agentd/install.sh"
sh "$root/apps/install.sh"
install -d -m 0755 /usr/local/share/caboose
if [[ "$mode" = *container ]]; then
  install -Dm755 "$root/container/caboose-session" /usr/local/bin/caboose-session
  install -Dm755 "$root/components/container-services.sh" /usr/local/libexec/caboose-components-services
else
  install -Dm644 "$root/components/caboose-workloads.slice" /etc/systemd/system/caboose-workloads.slice
  install -Dm755 "$root/components/caboose-owner-run" /usr/local/libexec/caboose-owner-run
  install -Dm755 "$root/template/caboose-template.py" /usr/local/libexec/caboose-template
  install -Dm644 "$root/template/caboose-template.target" /etc/systemd/system/caboose-template.target
  install -Dm755 "$root/components/caboose-vsock-services.py" /opt/caboose/vsock/caboose-vsock-services.py
  install -Dm644 "$root/components/caboose-vsock-services.service" /etc/systemd/system/caboose-vsock-services.service
  mkdir -p /var/lib/systemd/linger
  touch /var/lib/systemd/linger/caboose
  systemctl enable caboose-vsock-services.service caboose-files.service caboose-terminal.service caboose-notifications.service caboose-bridge.service var-lib-caboose-depot.mount
  systemctl disable cups.service cups.socket cups.path caboose-phone-printer.service
fi
if [[ "$mode" = vm ]]; then
  systemctl daemon-reload
  systemctl restart caboose-vsock-services.service
  systemctl restart caboose-notifications.service
  systemctl restart caboose-files.service
  systemctl restart caboose-terminal.service
  # Only a host that shares its runtime depot gives the computer the caboose-depot tag.
  systemctl start var-lib-caboose-depot.mount 2>/dev/null || :
  # The bridge runs with the owner's display; restart it only where that display is up.
  if systemctl is-active --quiet caboose-display.service; then systemctl restart caboose-bridge.service; fi
elif [[ "$mode" = container ]]; then
  /usr/local/libexec/caboose-components-services restart
fi
version=$(python3 "$root/components/version.py" "$root")
printf '%s\n' "$version" > /usr/local/share/caboose/components.version.tmp
mv -f /usr/local/share/caboose/components.version.tmp /usr/local/share/caboose/components.version

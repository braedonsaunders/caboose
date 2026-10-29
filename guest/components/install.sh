#!/bin/bash
# Install Caboose's own guest plumbing. The bundle is rooted at the parent of this file.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mode=${1:?expected image-vm, image-container, vm or container}
case "$mode" in image-vm|image-container|vm|container) ;; *) exit 2;; esac
export DEBIAN_FRONTEND=noninteractive
packages=(appstream gir1.2-appstream-1.0 cups cups-filters desktop-file-utils xdg-utils libnotify-bin python3-gi python3-websockets dbus-user-session libgl1-mesa-dri mesa-vulkan-drivers libgl1 xdg-desktop-portal xdg-desktop-portal-gtk geoclue-2.0 flatpak gir1.2-flatpak-1.0)
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
install -Dm755 "$root/files/caboose-files.py" /opt/caboose/files/caboose-files.py
install -Dm644 "$root/files/caboose-files.service" /etc/systemd/system/caboose-files.service
install -Dm755 "$root/terminal/caboose-terminal.py" /opt/caboose/terminal/caboose-terminal.py
install -Dm644 "$root/terminal/caboose-terminal.service" /etc/systemd/system/caboose-terminal.service
sh "$root/notifications/install.sh"
bash "$root/phone/install.sh"
sh "$root/bridge/install.sh"
sh "$root/flatpak/install.sh" "$mode"
sh "$root/agentd/install.sh"
install -d -m 0755 /usr/local/share/caboose
if [[ "$mode" = *container ]]; then
  install -Dm755 "$root/components/container-services.sh" /usr/local/libexec/caboose-components-services
else
  mkdir -p /var/lib/systemd/linger
  touch /var/lib/systemd/linger/caboose
  systemctl enable caboose-files.service caboose-terminal.service caboose-notifications.service cups.service caboose-phone-printer.service caboose-bridge.service var-lib-caboose-depot.mount
fi
if [[ "$mode" = vm ]]; then
  systemctl daemon-reload
  systemctl restart caboose-notifications.service
  systemctl restart caboose-files.service
  systemctl restart caboose-terminal.service
  systemctl start cups.service
  # Only a host that shares its runtime depot gives the computer the caboose-depot tag.
  systemctl start var-lib-caboose-depot.mount 2>/dev/null || :
  systemctl restart caboose-phone-printer.service
  # The bridge runs with the owner's display; restart it only where that display is up.
  if systemctl is-active --quiet caboose-display.service; then systemctl restart caboose-bridge.service; fi
elif [[ "$mode" = container ]]; then
  /usr/local/libexec/caboose-components-services restart
fi
version=$(python3 "$root/components/version.py" "$root")
printf '%s\n' "$version" > /usr/local/share/caboose/components.version.tmp
mv -f /usr/local/share/caboose/components.version.tmp /usr/local/share/caboose/components.version

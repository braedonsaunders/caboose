#!/bin/bash
# Install Caboose's own guest plumbing. The bundle is rooted at the parent of this file.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mode=${1:?expected image-vm, image-container, vm or container}
case "$mode" in image-vm|image-container|vm|container) ;; *) exit 2;; esac
export DEBIAN_FRONTEND=noninteractive
packages=(cups cups-filters desktop-file-utils xdg-utils libnotify-bin python3-gi dbus-user-session libgl1-mesa-dri mesa-vulkan-drivers libgl1)
missing=()
for pkg in "${packages[@]}"; do
  [ "$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || :)" = installed ] || missing+=("$pkg")
done
if ((${#missing[@]})); then
  log=$(mktemp /tmp/caboose-apt.XXXXXXXX)
  trap 'rm -f "$log"' EXIT
  if ! apt-get update >"$log" 2>&1 || ! apt-get install -y --no-install-recommends "${missing[@]}" >>"$log" 2>&1; then
    tail -n 80 "$log" >&2
    exit 1
  fi
  rm -f "$log"
  trap - EXIT
fi
install -Dm755 "$root/files/caboose-files.py" /opt/caboose/files/caboose-files.py
install -Dm644 "$root/files/caboose-files.service" /etc/systemd/system/caboose-files.service
sh "$root/notifications/install.sh"
bash "$root/phone/install.sh"
install -d -m 0755 /usr/local/share/caboose
if [[ "$mode" = *container ]]; then
  install -Dm755 "$root/container/caboose-session" /usr/local/bin/caboose-session
else
  mkdir -p /var/lib/systemd/linger
  touch /var/lib/systemd/linger/caboose
  systemctl enable caboose-files.service caboose-notifications.service cups.service caboose-phone-printer.service
fi
if [[ "$mode" = vm ]]; then
  systemctl daemon-reload
  systemctl restart caboose-notifications.service
  systemctl restart caboose-files.service
  systemctl start cups.service
  systemctl restart caboose-phone-printer.service
elif [[ "$mode" = container ]]; then
  if [ -s /run/caboose/files.pid ]; then
    pid=$(cat /run/caboose/files.pid)
    if [[ "$pid" =~ ^[0-9]+$ ]] && [ -r "/proc/$pid/cmdline" ] && tr '\0' '\n' < "/proc/$pid/cmdline" | grep -Fxq /opt/caboose/files/caboose-files.py; then
      start-stop-daemon --stop --signal TERM --pidfile /run/caboose/files.pid
      for _ in $(seq 1 10); do
        [ ! -r "/proc/$pid/stat" ] && break
        [ "$(awk '{print $3}' "/proc/$pid/stat")" = Z ] && break
        sleep 1
      done
      if [ -r "/proc/$pid/stat" ] && [ "$(awk '{print $3}' "/proc/$pid/stat")" != Z ]; then
        echo 'The previous Caboose file service did not stop.' >&2
        exit 1
      fi
    fi
    rm -f /run/caboose/files.pid
  fi
  /usr/local/bin/caboose-session start-files
  /usr/local/bin/caboose-session start-printing
fi
version=$(python3 "$root/components/version.py" "$root")
printf '%s\n' "$version" > /usr/local/share/caboose/components.version.tmp
mv -f /usr/local/share/caboose/components.version.tmp /usr/local/share/caboose/components.version

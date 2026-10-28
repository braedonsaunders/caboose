#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive USER=root HOME=/root TERM=xterm
printf 'deb https://deb.debian.org/debian trixie main contrib non-free-firmware\ndeb https://security.debian.org/debian-security trixie-security main contrib non-free-firmware\n' > /etc/apt/sources.list
apt-get -o APT::Acquire::Queue-Mode=access update
apt-get install -y --no-install-recommends ca-certificates curl gnupg
curl -fsSL https://xpra.org/xpra.asc -o /usr/share/keyrings/xpra.asc
curl -fsSL https://raw.githubusercontent.com/Xpra-org/xpra/v6.5.5/packaging/repos/trixie/xpra.sources -o /etc/apt/sources.list.d/xpra.sources
cat > /etc/apt/preferences.d/xpra <<'PIN'
Package: xpra xpra-*
Pin: version 6.5.5-r0-1
Pin-Priority: 1001
PIN
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft.gpg
printf 'deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main\n' > /etc/apt/sources.list.d/vscode.list
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg
printf 'deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main\n' > /etc/apt/sources.list.d/nodesource.list
apt-get -o APT::Acquire::Queue-Mode=access update
apt-get install -y --no-install-recommends linux-image-cloud-amd64 systemd-sysv dbus dbus-user-session initramfs-tools e2fsprogs sudo iproute2 socat python3 python3-gi gir1.2-gtk-3.0 python3-pyatspi dbus-x11 xauth xvfb x11-utils xdotool wmctrl xclip imagemagick ffmpeg x11vnc at-spi2-core xfce4-settings chromium firefox-esr code xfce4-terminal thunar mousepad libreoffice git ripgrep nodejs sassc libxml2-utils libglib2.0-bin libglib2.0-dev-bin fonts-inter fonts-jetbrains-mono fonts-noto-cjk fonts-noto-color-emoji qt5-gtk-platformtheme qt6-gtk-platformtheme libx264-164 python3-websockets xpra=6.5.5-r0-1 xpra-server=6.5.5-r0-1 xpra-x11=6.5.5-r0-1 xpra-common=6.5.5-r0-1 xpra-codecs=6.5.5-r0-1 xpra-codecs-extras=6.5.5-r0-1
for executable in gio xdotool wmctrl import xpra; do
  command -v "$executable" >/dev/null || { echo "Missing required guest executable: $executable" >&2; exit 1; }
done
npm install -g @anthropic-ai/claude-code @openai/codex
useradd -m -u 1000 -s /bin/bash caboose
usermod -aG sudo caboose
printf 'caboose ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/caboose
chmod 0440 /etc/sudoers.d/caboose
/tmp/desktop-mcp/install.sh
mkdir -p /opt/desk-agent/appkit-desk
for file in desk-guest-agent.mjs atspi-dump.py package.json desk-guest-agent.service desk-vsock-bridge.service; do
 curl -fsSL "https://raw.githubusercontent.com/braedonsaunders/bunkhouse/307f2eee512f27459843a588b38200f57abb6bcf/deploy/desk-image/agent/$file" -o "/tmp/$file"
done
cp /tmp/desk-guest-agent.mjs /tmp/atspi-dump.py /tmp/package.json /opt/desk-agent/
chmod +x /opt/desk-agent/atspi-dump.py
(cd /tmp && npm pack @braedonsaunders/appkit-desk@0.6.0 --silent && tar -xzf braedonsaunders-appkit-desk-0.6.0.tgz)
cp /tmp/package/{events,guest-agent,protocol}.js /opt/desk-agent/appkit-desk/
sed 's@HOME=/home/agent@HOME=/home/caboose@' /tmp/desk-guest-agent.service > /etc/systemd/system/desk-guest-agent.service
cp /tmp/desk-vsock-bridge.service /tmp/caboose-xpra.service /tmp/caboose-xpra-agent.service /etc/systemd/system/
systemctl disable xpra-server.socket xpra-server.service
systemctl enable desk-guest-agent.service desk-vsock-bridge.service
systemctl set-default multi-user.target
mkdir -p /tmp/themes
for spec in 'WhiteSur-gtk-theme d5782652d412137e26fb8ff55b55a5572e4c6995' 'WhiteSur-icon-theme 73d8040da51a9ed74e47c7366e7e9ff437601a5c' 'WhiteSur-cursors e190baf618ed95ee217d2fd45589bd309b37672b'; do
 set -- $spec
 git clone -q "https://github.com/vinceliuice/$1.git" "/tmp/themes/$1"
 git -C "/tmp/themes/$1" checkout -q "$2"
done
/tmp/themes/WhiteSur-gtk-theme/install.sh -d /usr/share/themes -c dark
/tmp/themes/WhiteSur-icon-theme/install.sh -d /usr/share/icons
(cd /tmp/themes/WhiteSur-cursors && ./install.sh)
mkdir -p /home/caboose/.cache /home/caboose/.config/gtk-3.0 /home/caboose/.config/gtk-4.0 /home/caboose/.config/xfce4/terminal
cat > /home/caboose/.config/xfce4/terminal/terminalrc <<'TERMINAL'
[Configuration]
FontName=JetBrains Mono 10
FontUseSystem=FALSE
TERMINAL
for v in 3.0 4.0; do
cat > "/home/caboose/.config/gtk-$v/settings.ini" <<'GTK'
[Settings]
gtk-theme-name=WhiteSur-Dark
gtk-icon-theme-name=WhiteSur-dark
gtk-cursor-theme-name=WhiteSur-cursors
gtk-font-name=Inter 10
gtk-decoration-layout=close,minimize,maximize:
gtk-application-prefer-dark-theme=1
GTK
done
cat > /etc/fonts/local.conf <<'FONTS'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <alias><family>sans-serif</family><prefer><family>Inter</family><family>Noto Sans CJK SC</family><family>Noto Color Emoji</family></prefer></alias>
  <alias><family>monospace</family><prefer><family>JetBrains Mono</family><family>Noto Sans CJK SC</family><family>Noto Color Emoji</family></prefer></alias>
</fontconfig>
FONTS
mkdir -p /etc/environment.d
printf 'QT_QPA_PLATFORMTHEME=gtk3\n' > /etc/environment.d/90-caboose.conf
chown -R caboose:caboose /home/caboose
printf 'caboose\n' > /etc/hostname
printf 'LABEL=caboose / ext4 defaults,noatime 0 1\ntmpfs /home/caboose/.cache tmpfs rw,nosuid,nodev,noatime,size=512M,uid=1000,gid=1000,mode=0700 0 0\n' > /etc/fstab
printf 'virtio_blk\nvirtio_pci\nvirtio_net\n' >> /etc/initramfs-tools/modules
update-initramfs -u
rm -f /etc/dpkg/dpkg.cfg.d/99-build-speed /etc/dpkg/dpkg.cfg.d/99-caboose-build
rm -f /etc/xpra/ssl/key.pem /etc/xpra/ssl/cert.pem
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/themes /tmp/package /tmp/*.tgz

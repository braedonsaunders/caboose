#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg sudo
install -d /usr/share/keyrings
curl -fsSL https://xpra.org/xpra.asc -o /usr/share/keyrings/xpra.asc
printf 'deb [signed-by=/usr/share/keyrings/xpra.asc] https://xpra.org trixie main\n' > /etc/apt/sources.list.d/xpra.list
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft.gpg
printf 'deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main\n' > /etc/apt/sources.list.d/vscode.list
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg
printf 'deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main\n' > /etc/apt/sources.list.d/nodesource.list
apt-get update
apt-get install -y xpra chromium firefox-esr code xfce4-terminal thunar mousepad libreoffice git ripgrep curl nodejs fonts-inter fonts-jetbrains-mono fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji adwaita-icon-theme gnome-themes-extra dbus-x11 at-spi2-core python3-pyatspi socat xvfb x11-utils xdotool wmctrl imagemagick ffmpeg xclip x11vnc xfce4-settings pulseaudio
npm install -g @anthropic-ai/claude-code@2.1.312 @openai/codex@0.165.0
id caboose >/dev/null 2>&1 || useradd -m -u 1000 -s /bin/bash -G sudo caboose
printf 'caboose ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/caboose
chmod 0440 /etc/sudoers.d/caboose
install -d -o caboose -g caboose /home/caboose/.config/gtk-3.0
printf '[Settings]\ngtk-theme-name=Adwaita-dark\ngtk-icon-theme-name=Adwaita\n' > /home/caboose/.config/gtk-3.0/settings.ini
chown caboose:caboose /home/caboose/.config/gtk-3.0/settings.ini
systemctl enable desk-guest-agent.service desk-vsock-bridge.service
systemctl set-default multi-user.target
apt-get clean

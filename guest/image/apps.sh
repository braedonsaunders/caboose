#!/usr/bin/env bash
# Install Caboose's phone-friendly app lineup in a Debian 13 guest or chroot.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
[[ $(id -u) == 0 ]] || { echo 'Run as root' >&2; exit 1; }
. /etc/os-release
[[ ${ID:-} == debian && ${VERSION_ID:-} == 13 && $(dpkg --print-architecture) == amd64 ]] || { echo 'Requires Debian 13 amd64' >&2; exit 1; }
apt-get update
apt-get install -y --no-upgrade --no-install-recommends \
  ca-certificates curl xz-utils python3-gi gir1.2-gtk-3.0 adwaita-icon-theme \
  mesa-vulkan-drivers libgl1-mesa-dri \
  chromium firefox-esr xfce4-terminal thunar mousepad libreoffice \
  evince keepassxc file-roller \
  git ripgrep fd-find bat eza fzf zoxide btop lazygit neovim tmux gh git-delta \
  jq curl wget unzip zip bzip2 tree ncdu htop fastfetch ffmpeg imagemagick docker.io docker-cli docker-compose mpv yt-dlp tealdeer \
  fonts-inter fonts-jetbrains-mono fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji
if ! command -v npm >/dev/null; then apt-get install -y nodejs npm; fi
# Pin the upstream tarball integrity as well as the package version. npm checks
# the downloaded tarballs and dependency integrity while installing.
install_npm() {
  local pkg=$1 integrity=$2
  if npm list -g --depth=0 2>/dev/null | grep -Fq "$pkg"; then return; fi
  [[ $(npm view "$pkg" dist.integrity) == "$integrity" ]] || { echo "Unexpected registry integrity for $pkg" >&2; exit 1; }
  npm install -g --no-audit --no-fund "$pkg"
}
install_npm '@anthropic-ai/claude-code@2.1.312' 'sha512-/gx8byG8VOm4YoNuT5tal/Ov5Z5oydJzZkmHCJcBFLbNGGpyYDbKA/CNdB+iIKwcLQC8pVwBoj6Dt7H3L2J5bw=='
install_npm '@openai/codex@0.165.0' 'sha512-aiwtQVp2KBhJld966CuU5bVfQ46VNB4mNTl6giX3WGZdt4euI3tv2RUqJpnupPNA8DXHg2z+RoQ0Zfw87dy8Lw=='
install_npm '@google/gemini-cli@0.66.0' 'sha512-EAtsJ9/JxiphHlduzvhoCkb7I0LdOxyugB5NpUtVqKVGZIWjV3JmurvK89ZrvMbV3kwk5SdWINz1M5ZN/2K/Lw=='
# Debian renames these binaries to avoid collisions with other packages.
for mapping in bat:batcat fd:fdfind; do
  name=${mapping%%:*}; target=${mapping#*:}
  if ! command -v "$name" >/dev/null; then ln -s "$(command -v "$target")" "/usr/local/bin/$name"; fi
done
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fetch() {
  local url=$1 sha=$2 output=$3
  curl -fsSL --retry 3 "$url" -o "$output"
  printf '%s  %s\n' "$sha" "$output" | sha256sum -c -
}
install_archive() {
  local name=$1 version=$2 url=$3 sha=$4 member=$5
  # Version markers prevent a second execution from redownloading large archives.
  local marker="/usr/local/share/caboose-apps/$name.version"
  if [[ -x /usr/local/bin/$name && -f $marker && $(cat "$marker") == "$version" ]]; then return; fi
  fetch "$url" "$sha" "$work/$name.tar.gz"
  tar -xOf "$work/$name.tar.gz" "$member" > "$work/$name"
  install -Dm755 "$work/$name" "/usr/local/bin/$name"
  install -d /usr/local/share/caboose-apps
  printf '%s\n' "$version" > "$marker"
}
install_archive opencode 1.19.4 'https://github.com/anomalyco/opencode/releases/download/v1.19.4/opencode-linux-x64-baseline.tar.gz' '1697ef40558d378bd2f72efa8fafe1bed1f0e664f09247b9357556b95dbc7cbc' opencode
install_archive lazydocker 0.25.2 'https://github.com/jesseduffield/lazydocker/releases/download/v0.25.2/lazydocker_0.25.2_Linux_x86_64.tar.gz' '0d9dbfc26068b218e7ed84b104748cadc6e3cf733c0afd35465306fb39b9523c' lazydocker
# uv runs the Python agents in the ACP registry (uvx); both binaries come from one archive.
if [[ $(uv --version 2>/dev/null) != 'uv 0.13.6'* ]]; then
  fetch 'https://github.com/astral-sh/uv/releases/download/0.13.6/uv-x86_64-unknown-linux-gnu.tar.gz' 'f29c3e94ffabd7e6f3ba521dba169a9b7ec12100bf3257087f0f24f6123f3645' "$work/uv.tar.gz"
  tar -xzf "$work/uv.tar.gz" -C "$work"
  install -m755 "$work/uv-x86_64-unknown-linux-gnu/uv" "$work/uv-x86_64-unknown-linux-gnu/uvx" /usr/local/bin/
fi
install_archive mise 2026.10.21 'https://github.com/jdx/mise/releases/download/v2026.10.21/mise-v2026.10.21-linux-x64.tar.gz' 'f56cc56b462eaae60aa7a33dffd24f641847b52e098b69e4a5064c4b8bbe03cb' mise/bin/mise
# Obsidian is upstream's proprietary .deb; pin and verify the exact release.
if [[ $(dpkg-query -W -f='${Version}' obsidian 2>/dev/null || true) != 1.14.5 ]]; then
  fetch 'https://github.com/obsidianmd/obsidian-releases/releases/download/v1.14.5/obsidian_1.14.5_amd64.deb' 'c37fb46a966f604823337fb36ab23bd1baf8ce912ec35af59d62358a93357bee' "$work/obsidian.deb"
  apt-get install -y "$work/obsidian.deb"
fi
# Application marks: pinned, checksum-verified Simple Icons (CC0) and OpenCode.
icon_dir=/usr/local/share/icons/hicolor/scalable/apps
install -d "$icon_dir" /usr/local/share/icons/hicolor/96x96/apps
for spec in \
  'claude 2d6fda79eb18ddccca35b799eeb3cece0dfabc22520ce3b10abd25668df9fa93 D97757' \
  'googlegemini a6228d8846040401e941a39ed17459785e8324dbb7b870ce84233c9b3e9863a0 4E8EF7' \
  'git 95724d436215d483de82288610c3c144854138f49945424697fcdf8be66e17d6 F05032' \
  'docker 65571291c261ef869c31540a38f3ca0f0ee3bb73f179c172211c8860f19a6359 2496ED'; do
  read -r name sha color <<< "$spec"
  fetch "https://raw.githubusercontent.com/simple-icons/simple-icons/90646e4bf7f3b89df6c37e65baf3e7bc759a517c/icons/$name.svg" "$sha" "$work/$name.svg"
  sed "s/<svg /<svg fill=\"#$color\" /" "$work/$name.svg" > "$icon_dir/caboose-$name.svg"
done
fetch 'https://opencode.ai/favicon-96x96-v3.png' 'aa34092540de60c889610edfa3c25316e215f12d88af29cfba530d09aee7265c' "$work/opencode.png"
install -m644 "$work/opencode.png" /usr/local/share/icons/hicolor/96x96/apps/caboose-opencode.png
# Terminal tools get genuine desktop entries and themed icons, not fake apps.
install -d /usr/local/share/applications
launcher() {
  local id=$1 name=$2 cmd=$3 icon=$4
  cat > "/usr/local/share/applications/caboose-$id.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=$name
Exec=/usr/bin/xfce4-terminal --disable-server --title=$name --execute $cmd
Icon=$icon
Categories=Development;Utility;
Terminal=false
StartupNotify=true
DESKTOP
}
launcher lazygit Lazygit /usr/bin/lazygit caboose-git
launcher btop btop /usr/bin/btop btop
launcher neovim Neovim /usr/bin/nvim nvim
launcher opencode OpenCode /usr/local/bin/opencode caboose-opencode
launcher claude Claude-Code "$(command -v claude)" caboose-claude
launcher codex Codex "$(command -v codex)" org.xfce.terminal
launcher gemini Gemini "$(command -v gemini)" caboose-googlegemini
launcher lazydocker Lazydocker /usr/local/bin/lazydocker caboose-docker
if id caboose >/dev/null 2>&1; then usermod -aG docker caboose; fi
systemctl enable docker.service
if [[ -d /run/systemd/system ]]; then systemctl start docker.service; fi
command -v update-desktop-database >/dev/null && update-desktop-database /usr/local/share/applications || true
# Media handoff: the Chromium extension and native host that offer a playing video to the
# phone. It lives beside this script in the repository; an image build that copies this
# script on its own (guest/container/Dockerfile) runs that installer itself.
media_handoff="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../media-handoff/install.sh"
if [[ -f $media_handoff ]]; then
  sh "$media_handoff"
else
  echo "Media handoff not installed: run guest/media-handoff/install.sh as root" >&2
fi

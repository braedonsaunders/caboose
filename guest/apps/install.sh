#!/bin/sh
# Install caboose-app and the caboose-apps MCP server at /opt/caboose/apps. Run as root by
# guest/components/install.sh, which installs WebKitGTK (gir1.2-webkit2-4.1) first. Each
# file is replaced atomically, so an open app keeps the code it loaded. Apps themselves live
# in the owner's home and are never touched here.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
dest=/opt/caboose/apps
install -d -m 0755 "$dest"
put() {
  install -m "$1" "$here/$2" "$dest/.$2.tmp"
  mv -f "$dest/.$2.tmp" "$dest/$2"
}
put 0644 appcore.py
put 0644 net.py
put 0644 remote.py
put 0644 page.js
put 0644 world.js
put 0644 guide.md
put 0755 caboose-app
put 0755 apps-mcp.mjs
ln -sfn "$dest/caboose-app" /usr/local/bin/caboose-app
python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import appcore, net' "$dest"

#!/bin/sh
# Install the Caboose WebMCP extension and its native messaging host for Chromium on the
# agent seat. Run as root, after Chromium; safe to run again. guest/components/install.sh
# runs it, so every computer gets it on its next component install.
set -eu
src=$(cd "$(dirname "$0")" && pwd)
dest=/opt/caboose/webmcp
# The extension ID follows from the public key in manifest.json; test_webmcp.py checks it.
extension_id=amcaiglphpdknhlheglmkglkdacedoab
install -d -m 0755 "$dest"
for file in manifest.json service-worker.js content.js page.js; do
    install -m 0644 "$src/$file" "$dest/$file"
done
install -m 0755 "$src/caboose-webmcp-host.py" "$dest/caboose-webmcp-host.py"
# Debian's Chromium reads system-wide native messaging hosts from here.
install -d -m 0755 /etc/chromium/native-messaging-hosts
cat > /etc/chromium/native-messaging-hosts/com.caboose.webmcp.json <<JSON
{
  "name": "com.caboose.webmcp",
  "description": "Caboose WebMCP: page tools for the agent seat's desktop tools",
  "path": "$dest/caboose-webmcp-host.py",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$extension_id/"]
}
JSON
chmod 0644 /etc/chromium/native-messaging-hosts/com.caboose.webmcp.json
if [ -d /etc/chromium.d ]; then
    install -m 0644 "$src/zz-caboose-agent" /etc/chromium.d/zz-caboose-agent
    rm -f /etc/chromium.d/caboose-accessibility  # folded into zz-caboose-agent
fi

#!/bin/sh
# Install the Caboose scroll reporters into the guest image, for every user. Run inside the
# image build (as root), after Chromium and Node are installed. Safe to run again. The GTK and
# Qt reporters are installed when built (gtk/build.sh, qt/build.sh, into their out/);
# caboose-display preloads every libcaboose-scroll-*.so in /opt/caboose/scroll-reporter/lib.
set -eu
src=$(cd "$(dirname "$0")" && pwd)
dest=/opt/caboose/scroll-reporter
# The extension ID follows from the public key in chromium/manifest.json.
extension_id=cnfgmfjajbhilcebcekcfckpfoapbkfn
install -d -m 0755 /opt/caboose "$dest" "$dest/chromium"
for file in manifest.json core.js content.js service-worker.js; do
    install -m 0644 "$src/chromium/$file" "$dest/chromium/$file"
done
install -m 0755 "$src/chromium/caboose-scroll-host.mjs" "$dest/chromium/caboose-scroll-host.mjs"
install -d -m 0755 /etc/chromium/native-messaging-hosts
cat > /etc/chromium/native-messaging-hosts/com.caboose.scroll.json <<JSON
{
  "name": "com.caboose.scroll",
  "description": "Caboose scroll reporter",
  "path": "$dest/chromium/caboose-scroll-host.mjs",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$extension_id/"]
}
JSON
chmod 0644 /etc/chromium/native-messaging-hosts/com.caboose.scroll.json
# Debian's /usr/bin/chromium loads every unpacked extension in /usr/share/chromium/extensions
# as one --load-extension list (guest/media-handoff/install.sh explains why it joins that list).
grep -qs /usr/share/chromium/extensions /etc/chromium.d/extensions || {
    echo 'Debian Chromium (with /etc/chromium.d/extensions) must be installed first' >&2; exit 1; }
install -d -m 0755 /usr/share/chromium/extensions
ln -sfn "$dest/chromium" /usr/share/chromium/extensions/caboose-scroll-reporter
install -d -m 0755 "$dest/lib"
for lib in "$src"/gtk/out/libcaboose-scroll-*.so "$src"/qt/out/libcaboose-scroll-*.so; do
    if [ -f "$lib" ]; then install -m 0644 "$lib" "$dest/lib/"; fi
done

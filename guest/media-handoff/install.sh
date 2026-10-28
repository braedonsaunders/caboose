#!/bin/sh
# Install the Caboose media handoff extension and its native messaging host into the guest
# image, for every Chromium profile. Run inside the image build (as root), after Chromium
# and Node are installed. Safe to run again.
set -eu
src=$(cd "$(dirname "$0")" && pwd)
dest=/opt/caboose/media-handoff
# The extension ID follows from the public key in manifest.json; selftest.mjs checks it.
extension_id=cklinclacpchpdgickgonlhnldfmkhbh
install -d -m 0755 /opt/caboose "$dest"
for file in manifest.json media-kind.js content.js service-worker.js; do
    install -m 0644 "$src/$file" "$dest/$file"
done
install -m 0755 "$src/caboose-media-host.mjs" "$dest/caboose-media-host.mjs"
# Debian's Chromium reads system-wide native messaging hosts from here.
install -d -m 0755 /etc/chromium/native-messaging-hosts
cat > /etc/chromium/native-messaging-hosts/com.caboose.media.json <<JSON
{
  "name": "com.caboose.media",
  "description": "Caboose media handoff",
  "path": "$dest/caboose-media-host.mjs",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$extension_id/"]
}
JSON
chmod 0644 /etc/chromium/native-messaging-hosts/com.caboose.media.json
# Debian's /usr/bin/chromium loads every unpacked extension in /usr/share/chromium/extensions
# (its /etc/chromium.d/extensions passes them as one --load-extension). Chromium honours only
# the last --load-extension switch, so a second one in another /etc/chromium.d file would be
# overridden; join Debian's list instead. Debian's Chromium build still honours the switch.
grep -qs /usr/share/chromium/extensions /etc/chromium.d/extensions || {
    echo 'Debian Chromium (with /etc/chromium.d/extensions) must be installed first' >&2; exit 1; }
install -d -m 0755 /usr/share/chromium/extensions
ln -sfn "$dest" /usr/share/chromium/extensions/caboose-media-handoff

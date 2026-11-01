#!/bin/sh
# Install the Caboose scroll reporters into the guest image, for every user. Run inside the
# image build (as root), after Chromium and Node are installed. Safe to run again. The GTK and
# Qt reporters are installed when built (gtk/build.sh, qt/build.sh, into their out/MULTIARCH),
# each architecture's into /opt/caboose/scroll-reporter/lib/MULTIARCH; caboose-display preloads
# them as /opt/caboose/scroll-reporter/$LIB/libcaboose-scroll-*.so, which the dynamic loader
# resolves to the process's own architecture.
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
# The reporter zooms pages through chrome.debugger; without this Chromium shows a banner
# saying the extension is debugging the browser.
cat > /etc/chromium.d/caboose-scroll <<'SH'
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --silent-debugger-extension-api"
SH
chmod 0644 /etc/chromium.d/caboose-scroll
install -d -m 0755 "$dest/lib" "$dest/electron"
install -m 0644 "$src/electron/main.js" "$dest/electron/main.js"
for built in "$src"/gtk/out/*/ "$src"/qt/out/*/; do
    [ -d "$built" ] || continue
    arch=$(basename "$built")
    install -d -m 0755 "$dest/lib/$arch"
    for lib in "$built"libcaboose-scroll-*.so; do
        if [ -f "$lib" ]; then install -m 0644 "$lib" "$dest/lib/$arch/"; fi
    done
done
# The computer's own architecture names the preloads; every other architecture installed
# must have each of them, or its processes would report a missing preload.
case $(uname -m) in
    x86_64) native=x86_64-linux-gnu ;;
    aarch64) native=aarch64-linux-gnu ;;
    *) echo "no multiarch triplet for $(uname -m)" >&2; exit 1 ;;
esac
names=$(cd "$dest/lib/$native" 2>/dev/null && ls libcaboose-scroll-*.so 2>/dev/null | grep -v -- '-quick\.so$' || true)
for arch in "$dest"/lib/*/; do
    for name in $names; do
        [ -f "$arch$name" ] || { echo "$arch lacks $name" >&2; exit 1; }
    done
done
# Flatpak applications see neither /opt nor the host's LD_PRELOAD: a system-wide override
# gives every one of them the libraries, read-only, and the display instances' sockets, where
# the reporters find their scroll socket from WAYLAND_DISPLAY.
if command -v flatpak >/dev/null 2>&1; then
    preload=$(for name in $names; do printf '%s/$LIB/%s\n' "$dest" "$name"; done | paste -sd: -)
    if [ -n "$preload" ]; then
        flatpak override --system --filesystem="$dest:ro" --filesystem=xdg-run/caboose-display \
            --env=LD_PRELOAD="$preload" --env=NODE_OPTIONS="--require=$dest/electron/main.js"
    fi
fi

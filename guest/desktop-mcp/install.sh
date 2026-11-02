#!/bin/sh
# Install caboose-desktop-mcp and its accessibility helper into the guest and switch on the
# accessibility trees of the apps it reads. caboose-agentd passes the server to every ACP
# agent in session/new, so no agent needs it registered. Run inside the image build (as
# root), after Node and the apps.
set -eu
here=$(dirname "$0")
install -d -m 0755 /opt/caboose
install -m 0755 "$here/caboose-desktop-mcp.mjs" /opt/caboose/desktop-mcp.mjs
install -m 0644 "$here/worker.mjs" "$here/ensure-agent-seat.mjs" /opt/caboose/
install -m 0755 "$here/a11y.py" "$here/seat.py" "$here/annotate.py" "$here/caboose-targets.py" /opt/caboose/
# The desktop-wide switch toolkits consult (org.a11y.Status IsEnabled follows it): Firefox,
# Qt and Chromium-based apps launched without Caboose's environment still expose a tree.
if [ -f /usr/share/glib-2.0/schemas/org.gnome.desktop.interface.gschema.xml ]; then
    printf '[org.gnome.desktop.interface]\ntoolkit-accessibility=true\n' \
        > /usr/share/glib-2.0/schemas/90_caboose-accessibility.gschema.override
    glib-compile-schemas /usr/share/glib-2.0/schemas
fi

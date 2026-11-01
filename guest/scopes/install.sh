#!/bin/sh
# App scopes (README.md): container computers only; under systemd the hierarchy is systemd's.
set -eu
here=$(dirname "$0")
install -d -m 0755 /opt/caboose/scopes
install -m 0755 "$here/caboose-scopes" /opt/caboose/scopes/caboose-scopes
install -m 0644 "$here/scopecore.py" /opt/caboose/scopes/scopecore.py
ln -sf /opt/caboose/scopes/caboose-scopes /usr/local/bin/caboose-scopes

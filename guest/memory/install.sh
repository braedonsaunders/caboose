#!/bin/sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
install -Dm755 "$here/caboose-memory.py" /opt/caboose/memory/caboose-memory.py
install -Dm755 "$here/caboose-memory.py" /usr/local/libexec/caboose-memory
install -Dm644 "$here/caboose-memory.service" /etc/systemd/system/caboose-memory.service

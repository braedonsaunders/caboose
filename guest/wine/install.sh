#!/bin/sh
# Wine prefixes for the phone's display (README.md). Container computers run the service under
# caboose-scopes (guest/scopes), microVMs under systemd.
set -eu
here=$(dirname "$0")
mode=${1:?expected image-vm, image-container, vm or container}
install -Dm755 "$here/caboose-wine-dpi" /opt/caboose/wine/caboose-wine-dpi
case "$mode" in
  *container)
    install -Dm644 "$here/caboose-wine-dpi.service" /etc/caboose/services/caboose-wine-dpi.service
    # A running service manager rereads the unit; the service itself takes the new code.
    if [ "$mode" = container ] && command -v caboose-scopes >/dev/null; then
      caboose-scopes service restart caboose-wine-dpi >/dev/null || :
    fi
    ;;
  *)
    install -Dm644 "$here/caboose-wine-dpi.service" /etc/systemd/system/caboose-wine-dpi.service
    systemctl enable caboose-wine-dpi.service
    if [ "$mode" = vm ]; then systemctl restart caboose-wine-dpi.service || :; fi
    ;;
esac

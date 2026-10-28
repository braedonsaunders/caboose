#!/bin/bash
set -euo pipefail
src=$(cd "$(dirname "$0")" && pwd)
install -Dm755 "$src/caboose-phone" /usr/local/bin/caboose-phone
ln -sfn caboose-phone /usr/local/bin/caboose-open
ln -sfn caboose-phone /usr/local/bin/caboose-share
install -Dm644 "$src/caboose-phone.desktop" /usr/local/share/applications/caboose-phone.desktop
install -Dm644 "$src/caboose-share.desktop" /usr/local/share/applications/caboose-share.desktop
update-desktop-database /usr/local/share/applications
# Default only phone-specific schemes, not ordinary web browsing.
install -d /etc/xdg
python3 - <<'PY'
import configparser
from pathlib import Path
p = Path('/etc/xdg/mimeapps.list')
c = configparser.ConfigParser(interpolation=None, strict=False)
c.optionxform = str
if p.exists(): c.read(p)
if not c.has_section('Default Applications'): c.add_section('Default Applications')
for scheme in ('mailto', 'tel', 'sms', 'facetime', 'facetime-audio', 'maps', 'geo'):
    c['Default Applications']['x-scheme-handler/' + scheme] = 'caboose-phone.desktop;'
with p.open('w') as f: c.write(f)
PY
# A system default leaves any owner-maintained Thunar actions untouched.
install -Dm644 "$src/uca.xml" /etc/xdg/Thunar/uca.xml
# Remove the generic printer's PJL wrapper so the backend receives a standalone PDF.
install -d /usr/local/share/caboose
sed '/^\*JCLToPDFInterpreter:/d' /usr/share/ppd/cupsfilters/Generic-PDF_Printer-PDF.ppd > /usr/local/share/caboose/phone.ppd
install -Dm700 "$src/cups-backend" /usr/lib/cups/backend/caboose-phone
install -Dm755 "$src/printer-setup" /usr/local/libexec/caboose-phone-printer-setup
install -Dm644 "$src/caboose-phone-printer.service" /etc/systemd/system/caboose-phone-printer.service

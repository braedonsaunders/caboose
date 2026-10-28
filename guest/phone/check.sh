#!/bin/bash
# Run inside a disposable Debian guest as root after installing guest/phone.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo 'Run as root' >&2; exit 1; }
command -v cupsd >/dev/null
command -v gs >/dev/null
lpstat -r 2>/dev/null | grep -q 'scheduler is running' || cupsd
/usr/local/libexec/caboose-phone-printer-setup
lpstat -p iPhone | grep -q iPhone
for scheme in mailto tel sms facetime facetime-audio maps geo; do
  actual=$(runuser -u caboose -- xdg-mime query default "x-scheme-handler/$scheme")
  [ "$actual" = caboose-phone.desktop ] || { echo "Unexpected $scheme handler: $actual" >&2; exit 1; }
done
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
printf 'hello phone\n' > "$work/example.txt"
chmod 755 "$work"
chmod 644 "$work/example.txt"
runuser -u caboose -- caboose-open 'mailto:person@example.com'
runuser -u caboose -- caboose-share "$work/example.txt"
printf '%%!PS\n/Helvetica findfont 20 scalefont setfont 72 720 moveto (Caboose) show showpage\n' > "$work/job.ps"
ps2pdf "$work/job.ps" "$work/job.pdf"
lp -d iPhone -t 'Caboose check' "$work/job.pdf"
for _ in $(seq 1 30); do
  if lpstat -W not-completed -o iPhone | grep -q .; then sleep 1; else break; fi
done
runuser -u caboose -- caboose-phone drain > "$work/events.json"
python3 - "$work/events.json" <<'PY'
import json, sys
items = json.load(open(sys.argv[1]))
assert any(i.get('type') == 'phone.open' and i.get('url') == 'mailto:person@example.com' for i in items), items
assert any(i.get('type') == 'phone.share' and i.get('name') == 'example.txt' and i.get('size') == 12 for i in items), items
assert any(i.get('type') == 'phone.print' and i.get('contentType') == 'application/pdf' and i.get('size', 0) > 0 for i in items), items
print('Open, share and CUPS print events passed')
PY

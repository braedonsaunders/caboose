"""Read Debian's AppStream pool; the host validates every returned field."""
import json
from pathlib import Path
import re
import subprocess
import sys

import gi
gi.require_version('AppStream', '1.0')
from gi.repository import AppStream

request = json.loads(sys.argv[1])
restore = request == {'restore': True}
if not restore and (not isinstance(request, str) or len(request) > 100 or any(ord(c) < 32 for c in request)):
    raise SystemExit('Invalid search')
query = '' if restore else request
pool = AppStream.Pool.new()
pool.load()
components = []
if restore:
    for file in sorted(Path('/var/lib/caboose/catalog').glob('debian-*.json'))[:500]:
        try:
            if file.stat().st_size > 65536:
                continue
            ident = json.loads(file.read_text()).get('storeComponent', '')
            if not isinstance(ident, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.+-]{0,199}', ident):
                continue
            matches = pool.get_components_by_id(ident)
            components.extend(matches.index_safe(i) for i in range(min(matches.get_size(), 10)))
        except (OSError, ValueError, AttributeError):
            continue
else:
    box = pool.search(query) if query else pool.get_components_by_kind(AppStream.ComponentKind.DESKTOP_APP)
    components = [box.index_safe(i) for i in range(min(box.get_size(), 20000))]

# A small editorial selection of well-known desktop apps, not a usage ranking.
picks = ('blender', 'thunderbird', 'krita', 'gimp', 'inkscape', 'vlc', 'audacity',
         'kdenlive', 'obs-studio', 'handbrake', 'libreoffice', 'darktable')
entries = []
seen = set()
for component in components:
    if component.get_kind() != AppStream.ComponentKind.DESKTOP_APP:
        continue
    packages = component.get_pkgnames() or []
    launch = component.get_launchable(AppStream.LaunchableKind.DESKTOP_ID)
    desktop = (launch.get_entries() if launch else [])
    if len(packages) != 1 or not desktop:
        continue
    package, desktop_id = packages[0], desktop[0]
    name, summary = component.get_name(), component.get_summary()
    if not re.fullmatch(r'[a-z0-9][a-z0-9+.-]{0,99}', package) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.+-]{0,199}\.desktop', desktop_id):
        continue
    if not name or not summary or package in seen:
        continue
    seen.add(package)
    categories = [c for c in (component.get_categories() or []) if re.fullmatch(r'[A-Za-z0-9-]{1,40}', c)][:12]
    entries.append({'id': 'debian-' + package, 'name': name[:160], 'summary': summary[:500],
                    'category': categories[0] if categories else 'Other', 'categories': categories,
                    'desktopId': desktop_id, 'package': package, 'curated': package in picks,
                    'license': (component.get_project_license() or '')[:200], 'componentId': (component.get_id() or '')[:200]})
if not query and not restore:
    entries.sort(key=lambda item: (not item['curated'], item['name'].casefold(), item['package']))
entries = entries[:500]
if entries:
    # One bounded APT query checks candidates for this guest's architecture.
    result = subprocess.run(['apt-cache', 'policy', *(entry['package'] for entry in entries)],
                            capture_output=True, text=True, timeout=15, check=True)
    candidates = set()
    current = None
    for line in result.stdout.splitlines():
        if re.fullmatch(r'[a-z0-9][a-z0-9+.-]{0,99}:', line):
            current = line[:-1]
        elif current and re.match(r'^\s*Candidate:\s*(?!\(none\)\s*$)\S+', line):
            candidates.add(current)
    entries = [entry for entry in entries if entry['package'] in candidates]
print(json.dumps(entries[:300 if restore else 100], ensure_ascii=True))

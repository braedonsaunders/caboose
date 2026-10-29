"""Rediscover the Debian apps the Library installed through AppStream before it offered
Flathub, from their operation records; the host validates every returned field."""
import json
from pathlib import Path
import re
import sys

import gi
gi.require_version('AppStream', '1.0')
from gi.repository import AppStream

if json.loads(sys.argv[1]) != {'restore': True}:
    raise SystemExit('Invalid request')
pool = AppStream.Pool.new()
pool.load()
components = []
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
    entries.append({'id': 'debian-' + package, 'name': name[:160], 'summary': summary[:500],
                    'desktopId': desktop_id, 'package': package,
                    'license': (component.get_project_license() or '')[:200], 'componentId': (component.get_id() or '')[:200]})
print(json.dumps(entries[:300], ensure_ascii=True))

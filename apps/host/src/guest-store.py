"""Read Debian's AppStream pool; the host validates every returned field."""
import json
from pathlib import Path
import re
import subprocess
import sys

import gi
gi.require_version('AppStream', '1.0')
from gi.repository import AppStream

query = json.loads(sys.argv[1])
if not isinstance(query, str) or len(query) > 100 or any(ord(c) < 32 for c in query):
    raise SystemExit('Invalid search')
pool = AppStream.Pool.new()
pool.load()
box = pool.search(query) if query else pool.get_components_by_kind(AppStream.ComponentKind.DESKTOP_APP)
entries = []
seen = set()
components = []
if not query:
    for file in sorted(Path('/var/lib/caboose/catalog').glob('debian-*.json'))[:500]:
        try:
            if file.stat().st_size > 65536:
                continue
            record = json.loads(file.read_text())
            ident = record.get('storeComponent', '')
            if not isinstance(ident, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.+-]{0,199}', ident):
                continue
            matches = pool.get_components_by_id(ident)
            components.extend(matches.index_safe(i) for i in range(min(matches.get_size(), 10)))
        except (OSError, ValueError, AttributeError):
            continue
components.extend(box.index_safe(i) for i in range(min(box.get_size(), 20000)))
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
    # APT's current architecture must actually have a candidate.
    candidate = subprocess.run(['apt-cache', 'show', '--no-all-versions', package], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
    if candidate.returncode:
        continue
    seen.add(package)
    categories = [c for c in (component.get_categories() or []) if re.fullmatch(r'[A-Za-z0-9-]{1,40}', c)][:12]
    entries.append({'id': 'debian-' + package, 'name': name[:160], 'summary': summary[:500],
                    'category': categories[0] if categories else 'Other', 'categories': categories,
                    'desktopId': desktop_id, 'package': package,
                    'license': (component.get_project_license() or '')[:200], 'componentId': (component.get_id() or '')[:200]})
    if len(entries) == 100:
        break
print(json.dumps(entries, ensure_ascii=True))

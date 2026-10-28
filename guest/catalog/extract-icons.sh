#!/bin/bash
# Writes icons/<id>.png and icons/<id>.LICENSE.txt for every apt app in catalog.json, taken
# from the app's own Debian 13 package. The container image and the Debian archive snapshot
# are pinned, so a re-run produces the same files; change SNAPSHOT to pick up newer packages.
#
#   guest/catalog/extract-icons.sh            # needs Docker; amd64 runs under emulation elsewhere
set -euo pipefail
IMAGE=debian:trixie@sha256:8c4733a92aacd0bcff3779eadc35a4a5147f36cb20a5fcb56504cbc740212259
SNAPSHOT=20261027T000000Z

if [[ ${1:-} != --inside ]]; then
  here=$(cd "$(dirname "$0")" && pwd)
  exec docker run --rm --platform linux/amd64 -e SNAPSHOT="$SNAPSHOT" -v "$here:/catalog" "$IMAGE" \
    bash /catalog/extract-icons.sh --inside
fi

export DEBIAN_FRONTEND=noninteractive
rm -f /etc/apt/sources.list.d/debian.sources
printf 'deb [check-valid-until=no] http://snapshot.debian.org/archive/%s/%s %s main\n' \
  debian "$SNAPSHOT" trixie debian-security "$SNAPSHOT" trixie-security > /etc/apt/sources.list
apt-get update -qq
apt-get install -y -qq --no-install-recommends apt-file librsvg2-bin python3-pil > /dev/null
apt-get update -qq  # again, now that apt-file has added the Contents indexes

exec python3 -I - <<'PY'
import glob, json, os, re, subprocess, sys, tempfile
from pathlib import Path
from PIL import Image

SIZE = 128
PREFERENCE = ('256x256/apps/{}.png', '128x128/apps/{}.png', 'scalable/apps/{}.svg', 'scalable/apps/{}.svgz')
catalog = Path('/catalog/catalog.json')
icons = Path('/catalog/icons')
apps = [app for app in json.loads(catalog.read_text())['apps'] if app['source']['kind'] == 'apt']
work = Path(tempfile.mkdtemp())
(work / 'debs').mkdir()
versions, sources = {}, {}
mismatched = []

def run(*args, cwd=None):
    return subprocess.run(args, check=True, capture_output=True, text=True, cwd=cwd).stdout

# Which packages ship each desktop entry and hicolor app icon, from the archive's Contents indexes.
shipped = {}
wanted = re.compile(r'usr/share/(?:applications/[^/]+\.desktop|icons/hicolor/(?:256x256|128x128|scalable)/apps/[^/]+)$')
for index in sorted(glob.glob('/var/lib/apt/lists/*_Contents-*')):
    for line in subprocess.run(['/usr/lib/apt/apt-helper', 'cat-file', index], check=True, capture_output=True, text=True).stdout.splitlines():
        path, _, owners = line.rpartition(' ')
        path = path.rstrip()
        if wanted.fullmatch(path):
            shipped.setdefault('/' + path, []).extend(owner.rsplit('/', 1)[-1] for owner in owners.split(','))

def source(pkg):
    if pkg not in sources:
        found = re.search(r'^Source: (\S+)', run('apt-cache', 'show', '--no-all-versions', pkg), re.M)
        sources[pkg] = found.group(1) if found else pkg
    return sources[pkg]

def owner(path, app):
    """The package from the app's own Debian source that ships path, if any."""
    own = {source(pkg) for pkg in app['source']['packages']}
    return next((pkg for pkg in sorted(set(shipped.get(path, []))) if source(pkg) in own), None)

def unpack(pkg):
    root = work / pkg
    if pkg not in versions:
        run('apt-get', 'download', pkg, cwd=work / 'debs')
        deb, = (work / 'debs').glob(f'{pkg}_*.deb')
        run('dpkg-deb', '-x', str(deb), str(root))
        versions[pkg] = run('dpkg-deb', '-f', str(deb), 'Version').strip()
    return root

def inside(root, path):
    """Resolves path's symlinks against the unpacked package rather than this container."""
    for _ in range(8):
        if not path.is_symlink():
            return path if path.is_file() and path.resolve().is_relative_to(root.resolve()) else None
        target = os.readlink(path)
        path = root / target.lstrip('/') if target.startswith('/') else path.parent / target
    return None

def icon_name(app):
    desktop = f"/usr/share/applications/{app['desktopId']}"
    pkg = owner(desktop, app)
    if not pkg:
        raise LookupError(f'no package from its source ships {desktop}')
    entry = (unpack(pkg) / desktop.lstrip('/')).read_text()
    section = re.search(r'^\[Desktop Entry\]$(.*?)(?=^\[|\Z)', entry, re.M | re.S)
    found = section and re.search(r'^Icon=(.+)$', section.group(1), re.M)
    if not found:
        raise LookupError(f'{desktop} in {pkg} has no Icon key')
    if found.group(1).strip() != app['icon']:
        mismatched.append(f"{app['id']}: {desktop} names icon {found.group(1).strip()}, not {app['icon']}; correct catalog.json")
    return found.group(1).strip()

def find(app):
    name = icon_name(app)
    for form in PREFERENCE:
        path = '/usr/share/icons/hicolor/' + form.format(name)
        if (pkg := owner(path, app)) and (file := inside(unpack(pkg), unpack(pkg) / path.lstrip('/'))):
            return pkg, path, file
    raise LookupError(f'no package from its source ships a 256, 128 or scalable hicolor icon named {name}')

def square(image):
    image = image.convert('RGBA')
    if image.size != (SIZE, SIZE):
        image.thumbnail((SIZE, SIZE), Image.LANCZOS)
        canvas = Image.new('RGBA', (SIZE, SIZE))
        canvas.paste(image, ((SIZE - image.width) // 2, (SIZE - image.height) // 2))
        image = canvas
    return image

def copyright(pkg):
    doc = unpack(pkg) / 'usr/share/doc' / pkg
    if doc.is_symlink():  # Debian lets a package's doc directory point at a dependency's
        pkg = os.path.basename(os.readlink(doc))
        doc = unpack(pkg) / 'usr/share/doc' / pkg
    return pkg, (doc / 'copyright').read_text()

stat = catalog.stat()
missing = []
for app in apps:
    try:
        pkg, path, file = find(app)
    except LookupError as error:
        missing.append(app['id'])
        print(f"{app['id']}: {error}", file=sys.stderr)
        continue
    if file.suffix == '.png':
        image = Image.open(file)
        image.load()
        how = 'copied' if image.size == (SIZE, SIZE) else f'scaled from {image.width}×{image.height} to {SIZE}×{SIZE}'
    else:
        rendered = work / f"{app['id']}.png"
        run('rsvg-convert', '--width', str(SIZE), '--height', str(SIZE), '--keep-aspect-ratio', '--output', str(rendered), str(file))
        image = Image.open(rendered)
        image.load()
        how = f'rendered at {SIZE}×{SIZE}'
    png = icons / f"{app['id']}.png"
    square(image).save(png, 'PNG', optimize=True)
    with Image.open(png) as check:
        assert check.size == (SIZE, SIZE) and check.mode == 'RGBA', png
    docpkg, text = copyright(pkg)
    licence = icons / f"{app['id']}.LICENSE.txt"
    licence.write_text(f"{app['name']} icon: {path} from the Debian 13 package {pkg} {versions[pkg]}, {how}.\n"
                       f"Copyright and licence follow, from /usr/share/doc/{docpkg}/copyright in {docpkg} {versions[docpkg]}.\n\n{text}")
    for written in (png, licence):
        os.chown(written, stat.st_uid, stat.st_gid)
    print(f"{app['id']}: {path} from {pkg} {versions[pkg]}, {how}")
for line in mismatched:
    print(line, file=sys.stderr)
sys.exit(1 if missing or mismatched else 0)
PY

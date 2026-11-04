#!/usr/bin/python3
"""Build the computer-use Debian packages from this directory.

usage: package.py OUTPUT-DIRECTORY

Builds caboose-computer-use_<version>_all.deb and, on amd64, caboose-computer-use-wine_<version>_amd64.deb
when wine/caboose-msaa.exe has been cross-built beside its source (the image builds do; a
computer updating from the host's component bundle has no cross compiler, and keeps the Wine
package it has). CABOOSE_MSAA names a built reader to package instead; CABOOSE_PACKAGE_ARCH
builds for another architecture than this one's. Each package's files and links are those debian/layout gives it.

The version is debian/changelog's, then `+` and the first 12 hex digits of a SHA-256 over the
package's paths, modes, links and contents, so changed contents always make a new version and
the same contents the same one. Every file carries one timestamp (SOURCE_DATE_EPOCH, else the
changelog's date), so a build is reproducible. Prints each package's path. Needs dpkg-deb.
"""
import email.utils
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
MSAA = 'wine/caboose-msaa.exe'


def source_path(source):
    if source == MSAA and os.environ.get('CABOOSE_MSAA'):
        return Path(os.environ['CABOOSE_MSAA'])
    return HERE / source
DEBIAN = HERE / 'debian'
ARCHITECTURES = {'caboose-computer-use': 'all', 'caboose-computer-use-wine': 'amd64'}


def layout():
    """{package: [(mode or 'link', source or target, destination)]} from debian/layout."""
    packages = {name: [] for name in ARCHITECTURES}
    for number, line in enumerate((DEBIAN / 'layout').read_text().splitlines(), 1):
        if not line.strip() or line.startswith('#'):
            continue
        fields = line.split()
        if len(fields) != 4 or fields[0] not in packages or not fields[3].startswith('/'):
            raise SystemExit(f'debian/layout:{number}: expected PACKAGE MODE|link SOURCE DESTINATION')
        package, kind, source, destination = fields
        if kind != 'link' and not re.fullmatch(r'0[0-7]{3}', kind):
            raise SystemExit(f'debian/layout:{number}: {kind} is not a mode')
        packages[package].append((kind, source, destination))
    return packages


def changelog():
    """The changelog's latest version and its date as a Unix time."""
    text = (DEBIAN / 'changelog').read_text()
    version = re.match(r'caboose-computer-use \(([^)]+)\)', text).group(1)
    date = re.search(r'^ -- .+?  (.+)$', text, re.M).group(1)
    return version, int(email.utils.parsedate_to_datetime(date).timestamp())


def digest(entries):
    hash_ = hashlib.sha256()
    for kind, source, destination in sorted(entries, key=lambda e: e[2]):
        hash_.update(f'{destination}\0{kind}\0'.encode())
        hash_.update(source.encode() if kind == 'link' else source_path(source).read_bytes())
        hash_.update(b'\0')
    return hash_.hexdigest()[:12]


def build(package, entries, version, stamp, output):
    root = Path(tempfile.mkdtemp(prefix=f'{package}-'))
    try:
        size = 0
        conffiles, md5sums = [], []
        for kind, source, destination in entries:
            target = root / destination.lstrip('/')
            target.parent.mkdir(parents=True, exist_ok=True)
            if kind == 'link':
                target.symlink_to(source)
                continue
            data = source_path(source).read_bytes()
            target.write_bytes(data)
            target.chmod(int(kind, 8))
            size += len(data)
            md5sums.append(f'{hashlib.md5(data).hexdigest()}  {destination.lstrip("/")}')
            if destination.startswith('/etc/'):
                conffiles.append(destination)
        control = root / 'DEBIAN'
        control.mkdir()
        text = (DEBIAN / f'{package}.control').read_text()
        (control / 'control').write_text(text.replace('@VERSION@', version).replace('@SIZE@', str(max(1, size // 1024))))
        if conffiles:
            (control / 'conffiles').write_text('\n'.join(sorted(conffiles)) + '\n')
        (control / 'md5sums').write_text('\n'.join(sorted(md5sums)) + '\n')
        for path in [root, *root.rglob('*')]:
            if path.is_dir() and not path.is_symlink():
                path.chmod(0o755)
            os.utime(path, (stamp, stamp), follow_symlinks=False)
        deb = output / f'{package}_{version}_{ARCHITECTURES[package]}.deb'
        env = dict(os.environ, SOURCE_DATE_EPOCH=str(stamp))
        subprocess.run(['dpkg-deb', '--root-owner-group', '-Zxz', '--build', str(root), str(deb)], check=True, env=env,
                       stdout=subprocess.DEVNULL)
        return deb
    finally:
        shutil.rmtree(root, ignore_errors=True)


def architecture():
    if os.environ.get('CABOOSE_PACKAGE_ARCH'):
        return os.environ['CABOOSE_PACKAGE_ARCH']
    return subprocess.run(['dpkg', '--print-architecture'], check=True, capture_output=True, text=True).stdout.strip()


def main(argv):
    if len(argv) != 1:
        raise SystemExit(__doc__.strip().splitlines()[2])
    output = Path(argv[0])
    output.mkdir(parents=True, exist_ok=True)
    base, dated = changelog()
    stamp = int(os.environ.get('SOURCE_DATE_EPOCH', dated))
    for package, entries in layout().items():
        files = [source for kind, source, _ in entries if kind != 'link']
        missing = [source for source in files if not source_path(source).is_file()]
        if package == 'caboose-computer-use-wine' and (missing or architecture() != 'amd64'):
            continue  # not cross-built here, or no x86-64 Wine to run it
        if missing:
            raise SystemExit(f'{package}: missing {", ".join(missing)}')
        print(build(package, entries, f'{base}+{digest(entries)}', stamp, output))


if __name__ == '__main__':
    main(sys.argv[1:])

#!/usr/bin/env python3
"""Install acceptance hooks in either unmkinitramfs main-archive layout."""
from pathlib import Path
import shutil
import sys


def inject(root, extra):
    candidates = [path for path in (root, root / "main")
                  if (path / "scripts/local-bottom/ORDER").is_file()]
    if len(candidates) != 1:
        raise ValueError("Expected exactly one extracted initramfs main ORDER file")
    main = candidates[0]
    directory = main / "scripts/local-bottom"
    order = directory / "ORDER"
    original = order.read_text()
    for name in ("00-caboose-device-check", "zz-caboose-boot-check"):
        shutil.copyfile(extra / name, directory / name)
        (directory / name).chmod(0o755)
    order.write_text('/scripts/local-bottom/00-caboose-device-check "$@"\n' + original
                     + '\n/scripts/local-bottom/zz-caboose-boot-check "$@"\n')
    return main


if __name__ == "__main__":
    print(inject(*map(Path, sys.argv[1:3])))

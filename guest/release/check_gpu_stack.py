#!/usr/bin/env python3
"""Checks that ROOT (a staged release payload, or / of a computer) holds the whole GPU stack:
the driver and both implicit layers for each architecture, at the computer's paths and in
each Flatpak "host" GL extension, every loader manifest naming a library that is there and of
its architecture, the GBM backend, the driconf entry, the warm-up, the broker and the global
Flatpak override's settings (README.md, "The GPU stack").

usage: check_gpu_stack.py ROOT"""
import json
from pathlib import Path
import sys

LIVE = Path("usr/local/lib/caboose-gpu-live")
EXTENSIONS = Path("var/lib/flatpak/extension")
# A Flatpak "host" GL extension: its directory, the sandbox path its files appear at, the
# ELF machine of its libraries and the suffix of its layer manifests.
HOSTS = (
    (EXTENSIONS / "org.freedesktop.Platform.GL.host/x86_64/1.4", "/usr/lib/x86_64-linux-gnu/GL/host", 62, ""),
    (EXTENSIONS / "org.freedesktop.Platform.GL32.host/x86_64/1.4", "/usr/lib/i386-linux-gnu/GL/host", 3, "_32"),
)
LIBRARIES = ("libvulkan_gfxstream.so", "libVkLayer_caboose_executor_switch.so", "libVkLayer_caboose_gpu_routing.so")
LAYERS = ("caboose_executor_switch", "caboose_gpu_routing")
FILES = ("usr/local/libexec/caboose-gpu-broker", "usr/local/libexec/caboose-gpu/broker.py",
         "usr/local/libexec/caboose-gpu/caboose-gpu-warmup", "usr/local/libexec/caboose-gpu/caboose-gpu-warmup-session",
         "usr/local/libexec/caboose-gpu/expected-features.json",
         "usr/lib/x86_64-linux-gnu/gbm/vgem_gbm.so", "usr/share/drirc.d/caboose-vgem.conf",
         str(LIVE / "caboose-driver.json"),
         str(HOSTS[0][0] / "lib/gbm/vgem_gbm.so"), str(HOSTS[0][0] / "lib/caboose-gpu-warmup"),
         str(HOSTS[0][0] / "share/drirc.d/caboose-vgem.conf"), str(HOSTS[1][0] / "share/drirc.d/caboose-vgem.conf"))
OVERRIDE = Path("var/lib/flatpak/overrides/global")
OVERRIDE_HAS = ("xdg-run/caboose-gpu", "DRIRC_CONFIGDIR=", "GBM_BACKENDS_PATH=")


def elf_machine(path: Path):
    head = path.read_bytes()[:20]
    return int.from_bytes(head[18:20], "little") if head[:4] == b"\x7fELF" else None


def problems(root: Path):
    found = []

    def need_library(path: Path, machine: int, named_by: str):
        if not path.is_file():
            found.append(f"{named_by} names {path.relative_to(root)}, which is missing")
        elif elf_machine(path) != machine:
            found.append(f"{path.relative_to(root)} is not built for ELF machine {machine}")

    def manifest(path: Path, key: str):
        if not path.is_file():
            found.append(f"missing {path.relative_to(root)}")
            return None
        try:
            return json.loads(path.read_text())[key]["library_path"]
        except (ValueError, KeyError, TypeError):
            found.append(f"{path.relative_to(root)} is not a Vulkan {key} manifest")
            return None

    # The computer's own: the driver's manifest beside it, the layers' in the loader's directory.
    for directory, machine, suffix in ((LIVE, 62, ""), (LIVE / "i386", 3, "_32")):
        for library in LIBRARIES:
            need_library(root / directory / library, machine, "the stack")
        named = manifest(root / directory / "icd.json", "ICD")
        if named:
            need_library(root / named.lstrip("/"), machine, str(directory / "icd.json"))
        for layer in LAYERS:
            name = f"usr/local/share/vulkan/implicit_layer.d/{layer}{suffix}.json"
            named = manifest(root / name, "layer")
            if named:
                need_library(root / named.lstrip("/"), machine, name)
    # Flatpak applications': the extension's manifests name libraries at the sandbox path.
    for extension, sandbox, machine, suffix in HOSTS:
        for library in LIBRARIES:
            need_library(root / extension / "lib" / library, machine, "the stack")
        manifests = [(extension / "vulkan/icd.d/caboose_gfxstream.json", "ICD")]
        manifests += [(extension / f"vulkan/implicit_layer.d/{layer}{suffix}.json", "layer") for layer in LAYERS]
        for path, key in manifests:
            named = manifest(root / path, key)
            if named is None:
                continue
            if not named.startswith(sandbox + "/"):
                found.append(f"{path} names {named}, outside the extension's sandbox path {sandbox}")
                continue
            need_library(root / extension / named[len(sandbox) + 1:], machine, str(path))
    for name in FILES:
        if not (root / name).is_file():
            found.append(f"missing {name}")
    override = root / OVERRIDE
    text = override.read_text() if override.is_file() else ""
    found += [f"{OVERRIDE} lacks {entry}" for entry in OVERRIDE_HAS if entry not in text]
    return found


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    found = problems(Path(argv[1]))
    for problem in found:
        print(f"FAIL GPU stack: {problem}")
    if not found:
        print("PASS GPU stack: driver, layers, manifests, GBM, driconf, warm-up, broker and override for both architectures")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

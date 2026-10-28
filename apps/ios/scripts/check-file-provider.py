#!/usr/bin/env python3
"""Check File Provider metadata; optionally inspect a signed .app without launching it."""
import argparse
import pathlib
import plistlib
import subprocess

GROUP = "group.com.braedonsaunders.caboose"
KEYCHAIN = "com.braedonsaunders.caboose.shared"
ROOT = pathlib.Path(__file__).resolve().parents[1]


def check_metadata(info, signed=False):
    extension = info["NSExtension"]
    assert extension["NSExtensionPointIdentifier"] == "com.apple.fileprovider-nonui"
    assert extension.get("NSExtensionFileProviderSupportsEnumeration") is True, "Missing enumeration capability"
    assert extension.get("NSExtensionFileProviderDocumentGroup") == GROUP, "Wrong document group"
    principal = extension["NSExtensionPrincipalClass"]
    assert principal.endswith(".FileProvider"), "Wrong principal class"
    if signed:
        assert principal == "CabooseFiles.FileProvider", "Unexpanded principal class"
        assert info["CFBundleIdentifier"] == "com.braedonsaunders.caboose.files"


def entitlements(bundle):
    result = subprocess.run(["codesign", "-d", "--entitlements", "-", str(bundle)],
                            check=True, capture_output=True)
    return plistlib.loads(result.stdout)


def check(app=None):
    check_metadata(plistlib.loads((ROOT / "Files/Info.plist").read_bytes()))
    print("PASS: source File Provider discovery metadata")
    if app:
        app = pathlib.Path(app)
        extension = app / "PlugIns/CabooseFiles.appex"
        assert extension.is_dir(), "File Provider extension is not embedded"
        check_metadata(plistlib.loads((extension / "Info.plist").read_bytes()), signed=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        pair = [entitlements(bundle) for bundle in (app, extension)]
        for item in pair:
            assert GROUP in item.get("com.apple.security.application-groups", []), "Missing app group"
            team = item["com.apple.developer.team-identifier"]
            assert f"{team}.{KEYCHAIN}" in item.get("keychain-access-groups", []), "Missing shared Keychain group"
        assert pair[0]["com.apple.developer.team-identifier"] == pair[1]["com.apple.developer.team-identifier"]
        print("PASS: embedded provider metadata, code signatures, shared app/Keychain groups and team")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path)
    args = parser.parse_args()
    check(args.app)

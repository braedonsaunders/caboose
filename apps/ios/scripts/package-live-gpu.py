#!/usr/bin/env python3
"""Package an already-built iOS runtime and one hash-pinned Vulkan provider.

No downloads or upstream builds. The caller supplies the matching retained
CMake tree and patched MoltenVK archive; the receipt records every input.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET


# The pinned headless backend closure. Do not glob arbitrary build archives:
# that would also include test, diagnostic and incompatible GLES targets.
ARCHIVES = (
    "adapter/libcaboose_gpu_native_runtime.a",
    "adapter/libcaboose_gfxstream_framebuffer.a",
    "adapter/libcaboose_gfxstream_connection.a",
    "upstream/host/libgfxstream_backend_static.a",
    "upstream/host/vulkan/libgfxstream-vulkan-server.a",
    "upstream/host/vulkan/emulated_textures/libemulated_textures.a",
    "upstream/host/compressed_textures/libgfxstream_host_compressed_textures.a",
    "upstream/common/etc/libgfxstream_etc.a",
    "upstream/host/vulkan/cereal/libOpenglRender_vulkan_cereal.a",
    "upstream/common/build_info/libgfxstream_common_build_info.a",
    "upstream/host/features/libgfxstream_features.a",
    "upstream/host/common/libgfxstream_host_common.a",
    "upstream/host/address_space/libgfxstream_host_address_space.a",
    "upstream/host/decoder_common/libgfxstream_host_decoder_common.a",
    "upstream/host/library/libgfxstream_host_library.a",
    "upstream/common/base/libgfxstream_common_base.a",
    "upstream/common/logging/libgfxstream_common_logging.a",
    "upstream/common/utils/libgfxstream_common_utils.a",
    "upstream/host/tracing/libgfxstream_host_tracing.a",
)
REQUIRED_EXPORTS = {"vkGetInstanceProcAddr", "vkGetDeviceProcAddr", "vkCreateInstance",
                    "vkDestroyInstance", "vkCreateDevice", "vkDestroyDevice"}


def digest(path):
    with Path(path).open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def provider_commands(nm_output, registry):
    """Only real defined exports which also have Vulkan registry declarations."""
    exported = {line[1:] for line in nm_output.splitlines()
                if re.fullmatch(r"_vk[A-Za-z0-9_]+", line)}
    declared = set()
    for command in ET.parse(registry).findall("./commands/command"):
        name = command.get("name") or command.findtext("proto/name")
        if name:
            declared.add(name)
    names = sorted(exported & declared)
    if not REQUIRED_EXPORTS <= set(names):
        raise ValueError("Provider is missing required Vulkan exports")
    return names


def provider_source(names):
    # Direct function-address references retain the actual provider trampolines
    # under dead stripping. No dlsym search, force_load, global export flags or
    # second loader. This table is dispatch plumbing, never a capability report.
    entries = "\n".join(f'    {{"{name}", reinterpret_cast<void*>(&{name})}},' for name in names)
    return '''#include <vulkan/vulkan.h>
#include "native_runtime.h"
#include "caboose_gpu_live.h"
#include <cstring>
namespace {
struct Export { const char* name; void* address; };
const Export exports[] = {
''' + entries + '''
};
void* resolve(const char* name) {
    if (!name) return nullptr;
    for (const auto& entry : exports) {
        if (std::strcmp(name, entry.name) == 0) return entry.address;
    }
    return nullptr;
}
}
extern "C" int caboose_gpu_live_start(void) {
    return caboose_gpu_runtime_start(&vkGetInstanceProcAddr, resolve);
}
'''


def run(argv, **kwargs):
    return subprocess.run(argv, check=True, timeout=90, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", required=True, type=Path)
    parser.add_argument("--provider", required=True, type=Path)
    parser.add_argument("--provider-sha256", required=True)
    parser.add_argument("--vulkan-headers", required=True, type=Path,
                        help="Pinned Vulkan-Headers checkout containing include/ and registry/")
    parser.add_argument("--output", required=True, type=Path,
                        help="New CabooseGPULive.xcframework directory; existing output is refused")
    args = parser.parse_args()
    if args.output.name != "CabooseGPULive.xcframework" or os.path.lexists(args.output):
        parser.error("output must be a new CabooseGPULive.xcframework")
    if not re.fullmatch(r"[0-9a-f]{64}", args.provider_sha256):
        parser.error("provider-sha256 must be a lowercase SHA-256")
    if digest(args.provider) != args.provider_sha256:
        parser.error("provider hash mismatch")
    ios = Path(__file__).resolve().parents[1]
    adapter = ios / "GPUStream/gfxstream"
    public_header = ios / "GPUStream/live/include/caboose_gpu_live.h"
    archives = [(args.build_dir / item).resolve(strict=True) for item in ARCHIVES]
    archives.append(args.provider.resolve(strict=True))
    input_hashes = {str(path): digest(path) for path in archives}
    cache = (args.build_dir / "CMakeCache.txt").read_text()
    for key, expected in (("CMAKE_OSX_ARCHITECTURES", "arm64"),
                          ("CABOOSE_GFXSTREAM_HOST_GLES", "0")):
        if not re.search(rf"^{key}:[^=]+={expected}$", cache, re.MULTILINE):
            parser.error(f"build cache must set {key}={expected}")
    if not re.search(r"^CMAKE_OSX_SYSROOT:[^=]+=.*(?:iphoneos|iPhoneOS[^/]*/?[^\n]*)$", cache, re.MULTILINE):
        parser.error("build must target the physical iOS SDK")
    for archive in archives:
        archs = run(["xcrun", "lipo", "-archs", str(archive)], capture_output=True, text=True).stdout.strip()
        if archs != "arm64":
            parser.error(f"expected one arm64 slice: {archive}")
    registry = args.vulkan_headers / "registry/vk.xml"
    symbols = run(["xcrun", "nm", "-gjU", str(args.provider)], capture_output=True, text=True).stdout
    names = provider_commands(symbols, registry)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".gpu-live-", dir=args.output.parent) as temp:
        work = Path(temp)
        source = work / "provider.cpp"
        source.write_text(provider_source(names))
        headers = work / "headers"
        headers.mkdir()
        (headers / public_header.name).write_bytes(public_header.read_bytes())
        (headers / "module.modulemap").write_text(
            'module CabooseGPULive { header "caboose_gpu_live.h" export * }\n')
        sdk = run(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], capture_output=True, text=True).stdout.strip()
        obj = work / "provider.o"
        run(["xcrun", "--sdk", "iphoneos", "clang++", "-std=c++17", "-target", "arm64-apple-ios26.0",
             "-isysroot", sdk, "-O2", "-DVK_USE_PLATFORM_METAL_EXT", "-DVK_USE_PLATFORM_IOS_MVK",
             "-DVK_USE_PLATFORM_MACOS_MVK", "-I", str(args.vulkan_headers / "include"),
             "-I", str(adapter), "-I", str(headers), "-c", str(source), "-o", str(obj)])
        merged = work / "libCabooseGPULive.a"
        run(["xcrun", "libtool", "-static", "-no_warning_for_no_symbols", "-o", str(merged),
             str(obj), *map(str, archives)])
        # A static archive merge alone cannot prove dependency closure. Import
        # the public module in Swift and link the actual start path into an iOS
        # executable. Never run this executable or install it on a device.
        probe = work / "LinkProbe.swift"
        probe.write_text('import CabooseGPULive\n@main struct LinkProbe { '
                         'static func main() { _ = caboose_gpu_live_start() } }\n')
        run(["xcrun", "--sdk", "iphoneos", "swiftc", "-parse-as-library",
             "-target", "arm64-apple-ios26.0", "-sdk", sdk,
             "-I", str(headers), "-L", str(work), "-lCabooseGPULive", "-lc++", "-lz",
             "-framework", "Foundation", "-framework", "CoreGraphics",
             "-framework", "IOSurface", "-framework", "Metal",
             "-framework", "QuartzCore", "-framework", "UIKit",
             str(probe), "-o", str(work / "LinkProbe")])
        framework = work / args.output.name
        run(["xcodebuild", "-create-xcframework", "-library", str(merged), "-headers", str(headers),
             "-output", str(framework)])
        if input_hashes != {str(path): digest(path) for path in archives}:
            raise RuntimeError("Native build inputs changed during packaging")
        receipt = {"format": 1, "platform": "ios-arm64", "deploymentTarget": "26.0",
                   "inputs": input_hashes, "swiftImportAndLink": "passed",
                   "linkProbeSHA256": digest(work / "LinkProbe"),
                   "registrySHA256": digest(registry), "headerSHA256": digest(public_header),
                   "providerSourceSHA256": digest(source), "exports": names,
                   "archiveSHA256": digest(merged)}
        (framework / "provenance.json").write_text(json.dumps(receipt, indent=2) + "\n")
        # Same filesystem rename, after complete generation. Never replace a
        # prior artifact or follow an output symlink.
        if os.path.lexists(args.output):
            raise FileExistsError(args.output)
        framework.rename(args.output)
    print(f"Packaged {args.output} ({len(names)} real provider exports)")


if __name__ == "__main__":
    main()

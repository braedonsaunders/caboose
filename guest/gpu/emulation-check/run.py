#!/usr/bin/env python3
"""Build serially and check offscreen Vulkan samples; never change driver feature reports."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

SOURCE = Path(__file__).resolve().parent


def bounded(argv, seconds, env=None):
    process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, start_new_session=True, env=env)
    try:
        stdout, stderr = process.communicate(timeout=seconds)
    except BaseException:
        # Only the process group this invocation created; no app/service-wide signals.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate()
        raise
    return process.returncode, stdout, stderr


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output', type=Path, required=True, help='New output directory (must not exist)')
    ap.add_argument('--headers', type=Path, required=True, help='Vulkan-Headers include directory')
    ap.add_argument('--moltenvk', type=Path, required=True, help='Stock macOS arm64 libMoltenVK.a')
    ap.add_argument('--moltenvk-sha256', required=True, help='Expected SHA256 of that archive')
    ap.add_argument('--developer-dir', type=Path, default=Path('/Applications/Xcode.app/Contents/Developer'))
    ap.add_argument('--case', action='append', choices=['control', 'cull_mixed_sign', 'geometry_direct',
                                                     'geometry_indirect', 'geometry_indexed_indirect'])
    args = ap.parse_args()
    if sys.platform != 'darwin':
        ap.error('This build entry point targets stock MoltenVK on macOS; render.cpp is ordinary Vulkan C++.')
    archive_hash = hashlib.sha256(args.moltenvk.read_bytes()).hexdigest()
    if archive_hash != args.moltenvk_sha256:
        ap.error('MoltenVK archive hash mismatch')
    args.output.mkdir(parents=True, exist_ok=False)
    out = args.output.resolve()
    env = dict(os.environ, DEVELOPER_DIR=str(args.developer_dir))
    # Reject injected capture/profiles/driver configuration: this is a stock-driver test.
    injected = [key for key in env if key.startswith(('VK_', 'MVK_', 'GFXRECON_'))]
    if injected:
        ap.error('Run without Vulkan/MoltenVK/capture overrides: ' + ', '.join(sorted(injected)))
    commands = []
    def command(argv, limit=30):
        commands.append(argv)
        code, stdout, stderr = bounded(argv, limit, env)
        if code:
            raise RuntimeError(f'{argv[0]} exited {code}:\n{stdout}\n{stderr}')
        return stdout.strip()
    started = time.monotonic()
    for name in ['control.vert', 'cull.vert', 'geometry.vert', 'geometry.geom', 'color.frag']:
        command(['glslangValidator', '-V', '--target-env', 'vulkan1.0', '-o', str(out / (name + '.spv')), str(SOURCE / name)])
        command(['spirv-val', '--target-env', 'vulkan1.0', str(out / (name + '.spv'))])
    sdk = command(['xcrun', '--sdk', 'macosx', '--show-sdk-path'])
    binary = out / 'render'
    compile_cmd = ['xcrun', '--sdk', 'macosx', 'clang++', '-std=c++20', '-O2', '-Wall', '-Wextra',
                   '-Wno-missing-field-initializers', '-target', 'arm64-apple-macos15.0', '-isysroot', sdk,
                   '-I' + str(args.headers.resolve()), str(SOURCE / 'render.cpp'), str(args.moltenvk.resolve()),
                   '-framework', 'Foundation', '-framework', 'AppKit', '-framework', 'Metal', '-framework', 'QuartzCore',
                   '-framework', 'IOKit', '-framework', 'IOSurface', '-framework', 'CoreGraphics',
                   '-o', str(binary)]
    command(compile_cmd, 60)
    spec = json.loads((SOURCE / 'expected.json').read_text())
    results = []
    for case in spec['tests']:
        if args.case and case['name'] not in args.case:
            continue
        name = case['name']
        pixels_file = out / (name + '.rgba')
        argv = [str(binary), str(out), name, str(pixels_file)]
        commands.append(argv)
        case_start = time.monotonic()
        try:
            code, stdout, stderr = bounded(argv, 15, env)
        except subprocess.TimeoutExpired:
            results.append({'name': name, 'status': 'FAIL', 'error': 'Owned renderer exceeded 15 seconds; killed and reaped'})
            continue
        (out / (name + '.stderr.log')).write_text(stderr)
        (out / (name + '.stdout.log')).write_text(stdout)
        result = {'name': name, 'elapsed_seconds': time.monotonic() - case_start}
        try:
            result.update(json.loads(stdout.strip().splitlines()[-1]))
        except (ValueError, IndexError):
            result.update(status='FAIL', error=f'No renderer report; exit {code}')
        if code == 77 and result.get('status') == 'UNSUPPORTED' and case['requiredFeatures'] and not pixels_file.exists():
            pass
        elif code == 0 and result.get('status') == 'RENDERED':
            pixels = pixels_file.read_bytes()
            if len(pixels) != 128 * 64 * 4:
                result.update(status='FAIL', error='Wrong readback size')
            else:
                samples = []
                for sample in case['samples']:
                    x, y = sample['xy']
                    offset = (y * 128 + x) * 4
                    actual = list(pixels[offset:offset + 4])
                    samples.append({'xy': [x, y], 'expected': sample['rgba'], 'actual': actual,
                                    'pass': actual == sample['rgba']})
                result.update(status='PASS' if all(s['pass'] for s in samples) else 'FAIL', samples=samples,
                              rgba_sha256=hashlib.sha256(pixels).hexdigest())
                # PPM is the actual readback, with alpha omitted; no synthetic image path.
                rgb = b''.join(pixels[i:i + 3] for i in range(0, len(pixels), 4))
                (out / (name + '.ppm')).write_bytes(b'P6\n128 64\n255\n' + rgb)
        else:
            result.update(status='FAIL', error=f'Renderer exited {code}')
        results.append(result)
        print(json.dumps(result), flush=True)
    report = {'moltenvk_archive_sha256': archive_hash,
              'render_source_sha256': hashlib.sha256((SOURCE / 'render.cpp').read_bytes()).hexdigest(),
              'expected_sha256': hashlib.sha256((SOURCE / 'expected.json').read_bytes()).hexdigest(),
              'elapsed_seconds': time.monotonic() - started, 'commands': commands, 'results': results,
              'scope': 'macOS offscreen render/readback; no phone, swapchain, game or fork validation'}
    (out / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    if hashlib.sha256(args.moltenvk.read_bytes()).hexdigest() != archive_hash:
        raise RuntimeError('Input driver changed during check')
    return int(any(r['status'] == 'FAIL' for r in results))


if __name__ == '__main__':
    raise SystemExit(main())

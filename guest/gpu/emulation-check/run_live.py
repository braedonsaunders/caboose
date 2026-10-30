#!/usr/bin/env python3
"""Check a prebuilt real Vulkan client; no builds, driver install or service changes."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import time

from run import bounded
from verify import verify_pixels


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--renderer', type=Path, required=True)
    parser.add_argument('--shaders', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--icd', type=Path, help='Explicit real ICD manifest for this process only')
    parser.add_argument('--case', action='append', choices=['control', 'compute_indirect', 'compute_cpu_feedback'])
    args = parser.parse_args()
    renderer, shaders = args.renderer.resolve(strict=True), args.shaders.resolve(strict=True)
    env = dict(os.environ)
    injected = [key for key in env if key.startswith(('VK_KHRONOS_PROFILES_', 'GFXRECON_'))]
    layers = env.get('VK_INSTANCE_LAYERS', '')
    if injected or 'profiles' in layers.lower() or 'gfxreconstruct' in layers.lower():
        parser.error('Capability simulation and capture overrides are not live feedback evidence')
    icd = args.icd.resolve(strict=True) if args.icd else None
    if icd:
        env.pop('VK_ICD_FILENAMES', None)
        env['VK_DRIVER_FILES'] = str(icd)
    spec_path = Path(__file__).with_name('expected.json')
    cases = {case['name']: case for case in json.loads(spec_path.read_text())['tests']}
    names = list(dict.fromkeys(args.case or ['compute_cpu_feedback']))
    required_shaders = sorted({name for n in names for name in cases[n]['stages']})
    hashes = {name: digest(shaders / (name + '.spv')) for name in required_shaders}
    renderer_hash = digest(renderer)
    args.output.mkdir(parents=True, exist_ok=False)
    out = args.output.resolve()
    results = []
    commands = []
    for name in names:
        case = cases[name]
        seed = (secrets.randbits(30) << 2) | 3
        rgba = out / (name + '.rgba')
        command = [str(renderer), str(shaders), name, str(rgba), str(seed)]
        commands.append(command)
        result = {'name': name, 'challenge': seed}
        started = time.monotonic()
        try:
            code, stdout, stderr = bounded(command, 15, env)
            (out / (name + '.stdout.log')).write_text(stdout)
            (out / (name + '.stderr.log')).write_text(stderr)
            result['exit'] = code
            if code:
                result.update(status='FAIL', error='Renderer failed; see private diagnostic logs')
            else:
                metadata = json.loads(stdout.strip().splitlines()[-1])
                result['renderer_report'] = metadata
                if not isinstance(metadata, dict) or metadata.get('status') != 'RENDERED':
                    result.update(status='FAIL', error='Missing completed renderer report')
                else:
                    result.update(verify_pixels(rgba.read_bytes(), case, metadata, expected_seed=seed))
        except subprocess.TimeoutExpired:
            result.update(status='FAIL', error='Renderer exceeded 15 seconds; owned process group killed and reaped')
        except (OSError, ValueError, IndexError, TypeError) as error:
            result.update(status='FAIL', error=type(error).__name__)
        result['elapsed_seconds'] = time.monotonic() - started
        results.append(result)
        print(json.dumps(result), flush=True)
    changed = digest(renderer) != renderer_hash or any(
        digest(shaders / (name + '.spv')) != value for name, value in hashes.items())
    report = {
        'scope': 'Live client Vulkan feedback; executor location requires independent matching device evidence',
        'renderer_sha256': renderer_hash, 'spirv_sha256': hashes,
        'expected_sha256': digest(spec_path), 'oracle_sha256': digest(Path(__file__).with_name('verify.py')),
        'icd_manifest_sha256': digest(icd) if icd else None,
        'commands': commands, 'results': results, 'inputs_changed': changed,
    }
    (out / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
    return int(changed or any(result['status'] != 'PASS' for result in results))


if __name__ == '__main__':
    raise SystemExit(main())

#!/usr/bin/env python3
"""The GPU feature names and bits every component agrees on (gpu-features.json), and checks.

    python3 gpu_features.py check REPO      every list matches gpu-features.json, or exit 1
    python3 gpu_features.py expected REPO   the expected-features.json a release installs

A phone declares features in X-Caboose-GPU-Features; the host relay forwards the ones it knows,
the broker admits and grants them, and each process's driver offers its own. A name one list
lacks is dropped there without an error: the phone then runs without it. These checks make
that drop fail a test instead (docs/gpu-live.md, "Feature negotiation").
"""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
CANONICAL = HERE / 'gpu-features.json'
CACHE_SESSION = 0x20000  # broker-local reply trailer every driver offers; not a phone feature
REQUIRED = 0x70  # the hello's required mask, never a feature

SWIFT = 'apps/ios/CabooseKit/Sources/CabooseKit/LiveGPUConnection.swift'
EXECUTOR = 'apps/ios/GPUStream/gfxstream/linux-executor/executor.py'
CHECK_DXVK = 'apps/ios/GPUStream/gfxstream/linux-executor/check-dxvk.sh'
RELAY = 'apps/host/src/gpu-relay.ts'
ADMISSION = 'guest/gpu/gfxstream/gpu_admission.py'
BROKER = 'guest/gpu/gfxstream/caboose-gpu-broker'
DRIVER = 'guest/gpu/gfxstream/SocketStream.cpp'
SILENT = 'guest/gpu/gfxstream/bounded-memory/silent_success.h'


def canonical(path=CANONICAL):
    """[{'name', 'bit' (int or None), 'requires', 'phone'}] from gpu-features.json."""
    features = json.loads(Path(path).read_text())['features']
    return [dict(f, bit=int(f['bit'], 16) if f['bit'] else None) for f in features]


def _names(text):
    return {name for name in re.findall(r"[a-z0-9]+(?:-[a-z0-9]+)*", text)}


def _block(text, start, end, what):
    at = text.find(start)
    if at < 0: raise ValueError(f'{what}: {start!r} not found')
    stop = text.find(end, at + len(start))
    if stop < 0: raise ValueError(f'{what}: no end of {start!r}')
    return text[at + len(start):stop]


def phone_app(repo):
    text = (Path(repo) / SWIFT).read_text()
    return set(re.search(r'static let features = "([^"]*)"', text).group(1).split(','))


def executor(repo):
    text = (Path(repo) / EXECUTOR).read_text()
    return set(''.join(re.findall(r"'([^']*)'", _block(text, 'FEATURES = (', ')', EXECUTOR))).split(','))


def check_dxvk(repo):
    text = (Path(repo) / CHECK_DXVK).read_text()
    return set(re.search(r'^phone=([a-z0-9,-]+)$', text, re.M).group(1).split(','))


def relay(repo):
    text = (Path(repo) / RELAY).read_text()
    return set(re.findall(r"'([a-z0-9-]+)'", _block(text, 'export const GPU_FEATURES = [', ']', RELAY)))


def admission(repo):
    text = (Path(repo) / ADMISSION).read_text()
    return set(re.findall(r"'([a-z0-9-]+)'", _block(text, '\nFEATURES = frozenset({', '})', ADMISSION)))


def _value(expression, names):
    total = 0
    for term in expression.split('|'):
        term = term.strip()
        if not term: continue
        total |= int(term, 16) if term.startswith('0x') else names[term]
    return total


def broker(repo):
    """({name: bit} the broker grants, {feature bit: bits it needs})."""
    text = (Path(repo) / BROKER).read_text()
    bits = {n: int(b, 16) for n, b in re.findall(r"'([a-z0-9-]+)':\s*(0x[0-9a-fA-F]+)",
                                                  _block(text, 'HELLO_FEATURES = {', '}', BROKER))}
    needs = {}
    for name, needed in (('NEEDS_GUEST_HANDLES', 0x80), ('NEEDS_COMPLETION_FEED', 0x200)):
        match = re.search(rf'^{name} = ([0x0-9a-fA-F |]+)', text, re.M)
        if match:
            for bit in range(32):
                if _value(match.group(1), {}) >> bit & 1: needs[1 << bit] = needs.get(1 << bit, 0) | needed
    return bits, needs


def driver_offer(repo):
    """The driver's first (fullest) hello offer."""
    text = (Path(repo) / DRIVER).read_text()
    names = {'caboose::silent::kHelloBit': None}
    silent = Path(repo) / SILENT
    if silent.exists():
        match = re.search(r'kHelloBit = (0x[0-9a-fA-F]+)', silent.read_text())
        if match: names['caboose::silent::kHelloBit'] = int(match.group(1), 16)
    for name, value in re.findall(r'\b(k[A-Z][A-Za-z]*) = (0x[0-9a-fA-F]+|caboose::silent::kHelloBit)', text):
        names[name] = names[value] if value.startswith('caboose') else int(value, 16)
    first = _block(text, 'static const uint32_t kOffers[] = {', ',', DRIVER)
    return _value(first, names)


def granted(offered, phone_bits, needs):
    """What the broker grants a process offering `offered` to a phone with `phone_bits`."""
    bits = offered & (phone_bits | CACHE_SESSION)
    for bit, need in needs.items():
        if bits & bit and bits & need != need: bits &= ~bit
    return bits


def problems(repo, features=None):
    """Every disagreement between a component's list and gpu-features.json, as sentences."""
    features = features if features is not None else canonical()
    names = {f['name'] for f in features}
    phone = {f['name'] for f in features if f['phone']}
    bits = {f['name']: f['bit'] for f in features if f['bit'] is not None}
    found = []

    def compare(what, have, want):
        if have != want:
            missing, extra = sorted(want - have), sorted(have - want)
            found.append(f'{what}: ' + '; '.join(
                part for part in (f'lacks {", ".join(missing)}' if missing else '',
                                  f'has {", ".join(extra)} not in gpu-features.json' if extra else '') if part))

    compare(f'phone app ({SWIFT})', phone_app(repo), phone)
    compare(f'Linux executor ({EXECUTOR} FEATURES)', executor(repo), phone)
    compare(f'DXVK check ({CHECK_DXVK} phone=)', check_dxvk(repo), phone)
    compare(f'host relay ({RELAY} GPU_FEATURES)', relay(repo), names)
    compare(f'broker admission ({ADMISSION} FEATURES)', admission(repo), names)
    broker_bits, needs = broker(repo)
    compare(f'broker ({BROKER} HELLO_FEATURES)', set(broker_bits), set(bits))
    for name in sorted(set(broker_bits) & set(bits)):
        if broker_bits[name] != bits[name]:
            found.append(f'broker ({BROKER}): {name} is {broker_bits[name]:#x}, gpu-features.json says {bits[name]:#x}')
    for f in features:
        if f['bit'] is None: continue
        want = 0
        for required in f['requires']: want |= bits[required]
        if needs.get(f['bit'], 0) != want:
            found.append(f'broker ({BROKER} NEEDS_*): {f["name"]} needs {needs.get(f["bit"], 0):#x}, gpu-features.json says {want:#x}')
    offer = driver_offer(repo)
    unoffered = sorted(n for n in phone if n in bits and not offer & bits[n])
    if unoffered: found.append(f'driver ({DRIVER} kOffers[0]): does not offer {", ".join(unoffered)}')
    unknown = offer & ~CACHE_SESSION & ~sum(set(bits.values()))
    if unknown: found.append(f'driver ({DRIVER} kOffers[0]): offers bits {unknown:#x} that gpu-features.json does not name')
    return found


def expected(repo, features=None):
    """What a phone session must negotiate with this checkout's components."""
    features = features if features is not None else canonical()
    bits = {f['name']: f['bit'] for f in features if f['bit'] is not None}
    phone = sorted(f['name'] for f in features if f['phone'])
    needs = broker(repo)[1]
    hello = granted(driver_offer(repo), sum(bits[n] for n in phone if n in bits), needs)
    return {'phone_features': phone,
            'hello_features': f'{hello:#x}',
            'hello_names': sorted(n for n, b in bits.items() if hello & b),
            'hello_bits': {n: f'{b:#x}' for n, b in sorted(bits.items()) if hello & b}}


def main(argv):
    if len(argv) != 3 or argv[1] not in ('check', 'expected'):
        print(__doc__.split('\n\n')[1], file=sys.stderr)
        return 2
    if argv[1] == 'expected':
        print(json.dumps(expected(argv[2]), indent=2))
        return 0
    found = problems(argv[2])
    for problem in found: print(f'CABOOSE_GPU_FEATURES_MISMATCH {problem}', file=sys.stderr)
    return 1 if found else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))

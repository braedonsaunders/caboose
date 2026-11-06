#!/usr/bin/env python3
"""Caboose guest memory compression (zram), MGLRU tuning, and active page reclamation."""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import sys
from typing import Callable, Sequence

MIN_ZRAM_DISKSIZE_BYTES = 256 * 1024 * 1024
PAGE_SIZE_BYTES = 4096

MEMINFO_KEYS = (
    'MemTotal',
    'MemFree',
    'MemAvailable',
    'Cached',
    'SReclaimable',
    'AnonPages',
    'SwapTotal',
    'SwapFree',
)

VM_SYSCTLS: tuple[tuple[str, str], ...] = (
    ('swappiness', '100'),
    ('page-cluster', '0'),
    ('watermark_boost_factor', '0'),
    ('watermark_scale_factor', '125'),
    ('vfs_cache_pressure', '150'),
)

RECLAIM_MODES = ('freeze', 'park', 'pressure')

Runner = Callable[[Sequence[str]], int]


def default_runner(command: Sequence[str]) -> int:
    try:
        completed = subprocess.run(
            list(command),
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=30,
        )
        return completed.returncode
    except (OSError, subprocess.SubprocessError):
        return 1


def _write_sysfs(path: pathlib.Path, value: str) -> bool:
    try:
        if not path.exists():
            return False
        path.write_text(value)
        return True
    except OSError:
        return False


def parse_meminfo(root: pathlib.Path = pathlib.Path('/')) -> dict[str, int]:
    meminfo_path = root / 'proc/meminfo'
    values: dict[str, int] = {key: 0 for key in MEMINFO_KEYS}
    try:
        raw = meminfo_path.read_text()
    except OSError:
        return values

    for line in raw.splitlines():
        if ':' not in line:
            continue
        key, rest = line.split(':', 1)
        key = key.strip()
        parts = rest.strip().split()
        if not parts:
            continue
        try:
            amount = int(parts[0])
        except ValueError:
            continue
        unit = parts[1].lower() if len(parts) > 1 else ''
        if unit == 'kb':
            amount *= 1024
        elif unit == 'mb':
            amount *= 1024 * 1024
        values[key] = amount
    return {key: values.get(key, 0) for key in MEMINFO_KEYS}


def parse_zram_mm_stat(
    root: pathlib.Path = pathlib.Path('/'),
    device: str = 'zram0',
) -> dict[str, int | float] | None:
    mm_stat_path = root / 'sys/block' / device / 'mm_stat'
    try:
        fields = mm_stat_path.read_text().strip().split()
    except OSError:
        return None
    if len(fields) < 3:
        return None
    try:
        numbers = [int(field) for field in fields]
    except ValueError:
        return None

    orig_data_size = numbers[0]
    compr_data_size = numbers[1]
    mem_used_total = numbers[2]
    if compr_data_size > 0:
        compression_ratio = round(orig_data_size / compr_data_size, 3)
    elif orig_data_size == 0:
        compression_ratio = 1.0
    else:
        compression_ratio = 0.0

    stat: dict[str, int | float] = {
        'orig_data_size': orig_data_size,
        'compr_data_size': compr_data_size,
        'mem_used_total': mem_used_total,
        'compression_ratio': compression_ratio,
    }
    optional_names = (
        'mem_limit',
        'mem_used_max',
        'same_pages',
        'pages_compacted',
        'huge_pages',
        'huge_pages_since',
    )
    for index, name in enumerate(optional_names, start=3):
        if index < len(numbers):
            stat[name] = numbers[index]
    return stat


def read_mglru_status(root: pathlib.Path = pathlib.Path('/')) -> dict[str, object]:
    lru_dir = root / 'sys/kernel/mm/lru_gen'
    enabled_path = lru_dir / 'enabled'
    min_ttl_path = lru_dir / 'min_ttl_ms'
    enabled_raw: str | None = None
    active = False
    try:
        if enabled_path.exists():
            enabled_raw = enabled_path.read_text().strip()
            try:
                active = int(enabled_raw, 0) > 0
            except ValueError:
                active = bool(enabled_raw and enabled_raw != '0')
    except OSError:
        enabled_raw = None

    min_ttl_ms: int | None = None
    try:
        if min_ttl_path.exists():
            min_ttl_ms = int(min_ttl_path.read_text().strip(), 0)
    except (OSError, ValueError):
        min_ttl_ms = None

    return {
        'supported': enabled_raw is not None,
        'enabled': enabled_raw,
        'active': active,
        'min_ttl_ms': min_ttl_ms,
    }


def calculate_zram_disksize(mem_total_bytes: int) -> int:
    half = max(0, mem_total_bytes) // 2
    clamped = max(MIN_ZRAM_DISKSIZE_BYTES, half)
    return (clamped // PAGE_SIZE_BYTES) * PAGE_SIZE_BYTES


def select_comp_algorithm(comp_algorithm_text: str) -> str:
    algorithms = [
        token.strip('[]')
        for token in comp_algorithm_text.split()
        if token.strip('[]')
    ]
    if 'zstd' in algorithms:
        return 'zstd'
    if 'lz4' in algorithms:
        return 'lz4'
    if algorithms:
        return algorithms[0]
    return 'zstd'


def is_zram_swap_active(
    root: pathlib.Path = pathlib.Path('/'),
    device: str = 'zram0',
) -> bool:
    swaps_path = root / 'proc/swaps'
    try:
        lines = swaps_path.read_text().splitlines()
    except OSError:
        return False
    for line in lines[1:]:
        fields = line.split()
        if not fields:
            continue
        name = fields[0].strip()
        if name == f'/dev/{device}' or name.endswith(f'/{device}'):
            return True
    return False


def setup(
    root: pathlib.Path = pathlib.Path('/'),
    runner: Runner | None = None,
) -> dict[str, object]:
    run_cmd = runner or default_runner
    run_cmd(['modprobe', '-q', 'zram'])
    run_cmd(['modprobe', '-q', 'virtio_balloon'])

    meminfo = parse_meminfo(root)
    disksize = calculate_zram_disksize(meminfo.get('MemTotal', 0))

    zram_dir = root / 'sys/block/zram0'
    zram_configured = False
    zram_algorithm: str | None = None
    zram_already_active = is_zram_swap_active(root, 'zram0')

    if zram_dir.exists() and not zram_already_active:
        comp_path = zram_dir / 'comp_algorithm'
        try:
            comp_text = comp_path.read_text() if comp_path.exists() else ''
        except OSError:
            comp_text = ''
        zram_algorithm = select_comp_algorithm(comp_text)
        _write_sysfs(comp_path, f'{zram_algorithm}\n')
        if _write_sysfs(zram_dir / 'disksize', f'{disksize}\n'):
            mkswap_rc = run_cmd(['mkswap', '/dev/zram0'])
            swapon_rc = run_cmd(['swapon', '-p', '100', '/dev/zram0'])
            zram_configured = mkswap_rc == 0 and swapon_rc == 0
    elif zram_already_active:
        comp_path = zram_dir / 'comp_algorithm'
        try:
            comp_text = comp_path.read_text() if comp_path.exists() else ''
            for token in comp_text.split():
                if token.startswith('[') and token.endswith(']'):
                    zram_algorithm = token.strip('[]')
                    break
            if not zram_algorithm and comp_text:
                zram_algorithm = select_comp_algorithm(comp_text)
        except OSError:
            zram_algorithm = None
        zram_configured = True

    lru_dir = root / 'sys/kernel/mm/lru_gen'
    mglru_enabled = False
    if (lru_dir / 'enabled').exists():
        mglru_enabled = _write_sysfs(lru_dir / 'enabled', '0x0007\n')
        _write_sysfs(lru_dir / 'min_ttl_ms', '1000\n')

    vm_dir = root / 'proc/sys/vm'
    applied_sysctls: dict[str, str] = {}
    for name, value in VM_SYSCTLS:
        if _write_sysfs(vm_dir / name, f'{value}\n'):
            applied_sysctls[name] = value

    return {
        'zram': {
            'configured': zram_configured,
            'already_active': zram_already_active,
            'algorithm': zram_algorithm,
            'disksize_bytes': disksize,
        },
        'mglru': read_mglru_status(root) | {'configured': mglru_enabled},
        'sysctls': applied_sysctls,
    }


def _proactive_reclaim_anonymous(
    root: pathlib.Path,
    mode: str,
    before_mem: dict[str, int],
) -> dict[str, object]:
    ratio = {'park': 0.50, 'freeze': 0.35}.get(mode, 0.35)
    anon_bytes = before_mem.get('AnonPages', 0)
    swap_free = before_mem.get('SwapFree', 0)
    requested_bytes = int(anon_bytes * ratio)
    if swap_free > 0:
        requested_bytes = min(requested_bytes, swap_free)
    requested_bytes = max(PAGE_SIZE_BYTES * 1024, (requested_bytes // PAGE_SIZE_BYTES) * PAGE_SIZE_BYTES)

    cgroup_targets = (
        root / 'sys/fs/cgroup/caboose-workloads.slice/memory.reclaim',
        root / 'sys/fs/cgroup/user.slice/memory.reclaim',
        root / 'sys/fs/cgroup/memory.reclaim',
    )
    cgroup_written: list[str] = []
    for target in cgroup_targets:
        try:
            if target.exists():
                target.write_text(f'{requested_bytes}\n')
                cgroup_written.append(str(target.relative_to(root)))
                break
        except OSError:
            continue

    mglru_aged = False
    admin_path = root / 'sys/kernel/mm/lru_gen/admin'
    try:
        if admin_path.exists():
            admin_path.write_text('0 0 1\n')
            mglru_aged = True
    except OSError:
        mglru_aged = False

    return {
        'requested_bytes': requested_bytes,
        'cgroup_targets': cgroup_written,
        'mglru_aged': mglru_aged,
    }


def reclaim(
    mode: str = 'freeze',
    root: pathlib.Path = pathlib.Path('/'),
    sync_fn: Callable[[], None] = os.sync,
) -> dict[str, object]:
    if mode not in RECLAIM_MODES:
        raise ValueError(f'Invalid reclaim mode: {mode}')

    before_mem = parse_meminfo(root)
    before_zram = parse_zram_mm_stat(root)

    try:
        sync_fn()
    except OSError:
        pass

    vm_dir = root / 'proc/sys/vm'
    if mode == 'pressure':
        # The computer is running, perhaps a game: give back only what nothing uses. Clean page
        # cache that no process maps is dropped; a program's mapped files (its binaries and
        # libraries) stay, and its memory is not pushed into zram, nor compacted, either of which
        # stalls it for seconds.
        proactive: dict[str, object] = {'requested_bytes': 0, 'cgroup_targets': [], 'mglru_aged': False}
        dropped_caches = _write_sysfs(vm_dir / 'drop_caches', '1\n')
        compacted = False
    else:
        proactive = _proactive_reclaim_anonymous(root, mode, before_mem)
        dropped_caches = _write_sysfs(vm_dir / 'drop_caches', '3\n')
        compacted = _write_sysfs(vm_dir / 'compact_memory', '1\n')

    after_mem = parse_meminfo(root)
    after_zram = parse_zram_mm_stat(root)

    freed_mem = max(0, after_mem.get('MemFree', 0) - before_mem.get('MemFree', 0))
    before_cache = before_mem.get('Cached', 0) + before_mem.get('SReclaimable', 0)
    after_cache = after_mem.get('Cached', 0) + after_mem.get('SReclaimable', 0)
    dropped_cache_bytes = max(0, before_cache - after_cache)
    reclaimed_bytes = max(freed_mem, dropped_cache_bytes)

    return {
        'mode': mode,
        'before': before_mem,
        'after': after_mem,
        'reclaimed_bytes': reclaimed_bytes,
        'dropped_caches': dropped_caches,
        'compacted': compacted,
        'proactive': proactive,
        'zram': {
            'before': before_zram,
            'after': after_zram,
            'current': after_zram,
        },
    }


def status(root: pathlib.Path = pathlib.Path('/')) -> dict[str, object]:
    meminfo = parse_meminfo(root)
    mglru = read_mglru_status(root)
    zram_stat = parse_zram_mm_stat(root)
    zram_active = is_zram_swap_active(root, 'zram0')
    return {
        'meminfo': meminfo,
        'mglru': mglru,
        'zram': {
            'active': zram_active,
            **(zram_stat or {
                'orig_data_size': 0,
                'compr_data_size': 0,
                'mem_used_total': 0,
                'compression_ratio': 1.0,
            }),
        },
    }


def main(
    argv: Sequence[str] | None = None,
    root: pathlib.Path = pathlib.Path('/'),
    runner: Runner | None = None,
    sync_fn: Callable[[], None] = os.sync,
) -> int:
    parser = argparse.ArgumentParser(prog='caboose-memory')
    subparsers = parser.add_subparsers(dest='subcommand', required=True)

    setup_parser = subparsers.add_parser('setup')
    setup_parser.add_argument('--json', action='store_true')

    reclaim_parser = subparsers.add_parser('reclaim')
    reclaim_parser.add_argument(
        '--mode',
        choices=RECLAIM_MODES,
        default='freeze',
    )
    reclaim_parser.add_argument('--json', action='store_true')

    status_parser = subparsers.add_parser('status')
    status_parser.add_argument('--json', action='store_true')

    args = parser.parse_args(list(argv) if argv is not None else None)

    if args.subcommand == 'setup':
        result = setup(root=root, runner=runner)
        if args.json:
            print(json.dumps(result))
        return 0
    if args.subcommand == 'reclaim':
        result = reclaim(mode=args.mode, root=root, sync_fn=sync_fn)
        print(json.dumps(result))
        return 0
    if args.subcommand == 'status':
        result = status(root=root)
        print(json.dumps(result))
        return 0
    return 2


if __name__ == '__main__':
    sys.exit(main())

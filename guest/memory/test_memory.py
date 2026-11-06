#!/usr/bin/env python3
"""Unit tests for Caboose guest memory subsystem (zram, MGLRU, and page reclamation)."""
from __future__ import annotations

import importlib.util
import io
import json
import pathlib
import tempfile
import unittest
from contextlib import redirect_stdout

MODULE_PATH = pathlib.Path(__file__).with_name('caboose-memory.py')
SPEC = importlib.util.spec_from_file_location('caboose_memory', MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
caboose_memory = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(caboose_memory)


def populate_fake_root(
    root: pathlib.Path,
    *,
    mem_total_kb: int = 6291456,
    mem_free_kb: int = 524288,
    mem_available_kb: int = 2097152,
    cached_kb: int = 1048576,
    sreclaimable_kb: int = 262144,
    anon_kb: int = 1572864,
    swap_total_kb: int = 3145728,
    swap_free_kb: int = 2621440,
    comp_algorithm: str = 'lzo lzo-rle [lz4] zstd',
    swaps_content: str = 'Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority\n',
    mm_stat: str = '402653184 117440512 125829120 0 125829120 1024 512 2048 1024\n',
    with_zram: bool = True,
    with_mglru: bool = True,
) -> None:
    proc = root / 'proc'
    vm = proc / 'sys/vm'
    vm.mkdir(parents=True, exist_ok=True)

    (proc / 'meminfo').write_text(
        f'MemTotal:       {mem_total_kb} kB\n'
        f'MemFree:        {mem_free_kb} kB\n'
        f'MemAvailable:   {mem_available_kb} kB\n'
        f'Cached:         {cached_kb} kB\n'
        f'SReclaimable:   {sreclaimable_kb} kB\n'
        f'AnonPages:      {anon_kb} kB\n'
        f'SwapTotal:      {swap_total_kb} kB\n'
        f'SwapFree:       {swap_free_kb} kB\n'
    )
    (proc / 'swaps').write_text(swaps_content)

    for sysctl in (
        'swappiness',
        'page-cluster',
        'watermark_boost_factor',
        'watermark_scale_factor',
        'vfs_cache_pressure',
        'drop_caches',
        'compact_memory',
    ):
        (vm / sysctl).write_text('0\n')

    if with_zram:
        zram = root / 'sys/block/zram0'
        zram.mkdir(parents=True, exist_ok=True)
        (zram / 'comp_algorithm').write_text(comp_algorithm + '\n')
        (zram / 'disksize').write_text('0\n')
        (zram / 'mm_stat').write_text(mm_stat)

    if with_mglru:
        lru_gen = root / 'sys/kernel/mm/lru_gen'
        lru_gen.mkdir(parents=True, exist_ok=True)
        (lru_gen / 'enabled').write_text('0x0000\n')
        (lru_gen / 'min_ttl_ms').write_text('0\n')
        (lru_gen / 'admin').write_text('0\n')

    cgroup_slice = root / 'sys/fs/cgroup/caboose-workloads.slice'
    cgroup_slice.mkdir(parents=True, exist_ok=True)
    (cgroup_slice / 'memory.reclaim').write_text('0\n')


class CabooseMemoryTest(unittest.TestCase):
    def test_calculate_zram_disksize_50_percent_and_clamp(self) -> None:
        six_gib = 6 * 1024 * 1024 * 1024
        self.assertEqual(
            caboose_memory.calculate_zram_disksize(six_gib),
            3 * 1024 * 1024 * 1024,
        )
        small = 128 * 1024 * 1024
        self.assertEqual(
            caboose_memory.calculate_zram_disksize(small),
            caboose_memory.MIN_ZRAM_DISKSIZE_BYTES,
        )

    def test_select_comp_algorithm_prefers_zstd_then_lz4(self) -> None:
        self.assertEqual(
            caboose_memory.select_comp_algorithm('lzo lzo-rle [lz4] zstd'),
            'zstd',
        )
        self.assertEqual(
            caboose_memory.select_comp_algorithm('lzo [lzo-rle] lz4'),
            'lz4',
        )

    def test_setup_configures_zram_mglru_and_sysctls(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            populate_fake_root(root)
            commands: list[list[str]] = []

            def fake_runner(cmd: caboose_memory.Sequence[str]) -> int:
                commands.append(list(cmd))
                return 0

            result = caboose_memory.setup(root=root, runner=fake_runner)

            self.assertIn(['modprobe', '-q', 'zram'], commands)
            self.assertIn(['modprobe', '-q', 'virtio_balloon'], commands)
            self.assertIn(['mkswap', '/dev/zram0'], commands)
            self.assertIn(['swapon', '-p', '100', '/dev/zram0'], commands)

            self.assertEqual(
                (root / 'sys/block/zram0/comp_algorithm').read_text().strip(),
                'zstd',
            )
            expected_disksize = 3 * 1024 * 1024 * 1024
            self.assertEqual(
                int((root / 'sys/block/zram0/disksize').read_text().strip()),
                expected_disksize,
            )
            self.assertEqual(
                (root / 'sys/kernel/mm/lru_gen/enabled').read_text().strip(),
                '0x0007',
            )
            self.assertEqual(
                (root / 'sys/kernel/mm/lru_gen/min_ttl_ms').read_text().strip(),
                '1000',
            )
            self.assertEqual(
                (root / 'proc/sys/vm/swappiness').read_text().strip(),
                '100',
            )
            self.assertEqual(
                (root / 'proc/sys/vm/page-cluster').read_text().strip(),
                '0',
            )
            self.assertEqual(
                (root / 'proc/sys/vm/watermark_boost_factor').read_text().strip(),
                '0',
            )
            self.assertEqual(
                (root / 'proc/sys/vm/watermark_scale_factor').read_text().strip(),
                '125',
            )
            self.assertEqual(
                (root / 'proc/sys/vm/vfs_cache_pressure').read_text().strip(),
                '150',
            )
            self.assertTrue(result['zram']['configured'])
            self.assertEqual(result['zram']['algorithm'], 'zstd')

    def test_setup_skips_zram_init_when_already_active(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            populate_fake_root(
                root,
                comp_algorithm='lzo [zstd] lz4',
                swaps_content=(
                    'Filename\tType\tSize\tUsed\tPriority\n'
                    '/dev/zram0                              partition\t3145724\t1024\t100\n'
                ),
            )
            commands: list[list[str]] = []

            def fake_runner(cmd: caboose_memory.Sequence[str]) -> int:
                commands.append(list(cmd))
                return 0

            result = caboose_memory.setup(root=root, runner=fake_runner)
            self.assertTrue(result['zram']['already_active'])
            self.assertNotIn(['mkswap', '/dev/zram0'], commands)
            self.assertNotIn(['swapon', '-p', '100', '/dev/zram0'], commands)

    def test_reclaim_syncs_drops_caches_compacts_and_reports_summary(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            populate_fake_root(root)
            synced = {'count': 0}

            def fake_sync() -> None:
                synced['count'] += 1
                # Simulate kernel dropping 768 MiB of page cache + slab when sync + reclaim runs
                (root / 'proc/meminfo').write_text(
                    'MemTotal:       6291456 kB\n'
                    'MemFree:        1310720 kB\n'
                    'MemAvailable:   2883584 kB\n'
                    'Cached:         262144 kB\n'
                    'SReclaimable:   131072 kB\n'
                    'AnonPages:      1310720 kB\n'
                    'SwapTotal:      3145728 kB\n'
                    'SwapFree:       2359296 kB\n'
                )

            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = caboose_memory.main(
                    ['reclaim', '--mode=freeze', '--json'],
                    root=root,
                    sync_fn=fake_sync,
                )
            self.assertEqual(rc, 0)
            self.assertEqual(synced['count'], 1)
            self.assertEqual(
                (root / 'proc/sys/vm/drop_caches').read_text().strip(),
                '3',
            )
            self.assertEqual(
                (root / 'proc/sys/vm/compact_memory').read_text().strip(),
                '1',
            )

            summary = json.loads(buf.getvalue())
            self.assertEqual(summary['mode'], 'freeze')
            self.assertTrue(summary['dropped_caches'])
            self.assertTrue(summary['compacted'])
            self.assertGreater(summary['reclaimed_bytes'], 700 * 1024 * 1024)
            self.assertIn('before', summary)
            self.assertIn('after', summary)
            self.assertIn('zram', summary)
            self.assertAlmostEqual(
                summary['zram']['after']['compression_ratio'],
                round(402653184 / 117440512, 3),
            )

    def test_status_returns_meminfo_mglru_and_zram_stats(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            populate_fake_root(
                root,
                swaps_content=(
                    'Filename\tType\tSize\tUsed\tPriority\n'
                    '/dev/zram0 partition 3145724 114688 100\n'
                ),
            )
            (root / 'sys/kernel/mm/lru_gen/enabled').write_text('0x0007\n')
            (root / 'sys/kernel/mm/lru_gen/min_ttl_ms').write_text('1000\n')

            buf = io.StringIO()
            with redirect_stdout(buf):
                rc = caboose_memory.main(['status', '--json'], root=root)
            self.assertEqual(rc, 0)
            payload = json.loads(buf.getvalue())
            self.assertEqual(payload['meminfo']['MemTotal'], 6291456 * 1024)
            self.assertTrue(payload['mglru']['supported'])
            self.assertTrue(payload['mglru']['active'])
            self.assertEqual(payload['mglru']['min_ttl_ms'], 1000)
            self.assertTrue(payload['zram']['active'])
            self.assertEqual(payload['zram']['orig_data_size'], 402653184)
            self.assertEqual(payload['zram']['compr_data_size'], 117440512)
            self.assertEqual(payload['zram']['mem_used_total'], 125829120)
            self.assertGreater(payload['zram']['compression_ratio'], 3.4)

    def test_pressure_reclaim_leaves_a_running_program_alone(self) -> None:
        """Under host pressure a running computer drops only unmapped clean page cache: no
        proactive anonymous reclaim into zram, no slab drop, no compaction."""
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            populate_fake_root(root)
            compact = root / 'proc/sys/vm/compact_memory'
            before_compact = compact.read_text() if compact.exists() else None
            reclaims = [root / 'sys/fs/cgroup/caboose-workloads.slice/memory.reclaim', root / 'sys/fs/cgroup/user.slice/memory.reclaim', root / 'sys/fs/cgroup/memory.reclaim']
            before_reclaims = [p.read_text() if p.exists() else None for p in reclaims]
            result = caboose_memory.reclaim(mode='pressure', root=root, sync_fn=lambda: None)
            self.assertEqual((root / 'proc/sys/vm/drop_caches').read_text().strip(), '1')
            self.assertEqual(compact.read_text() if compact.exists() else None, before_compact)
            self.assertEqual([p.read_text() if p.exists() else None for p in reclaims], before_reclaims)
            self.assertFalse(result['compacted'])
            self.assertEqual(result['proactive']['requested_bytes'], 0)

    def test_graceful_handling_in_restricted_container_environment(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            populate_fake_root(root, with_zram=False, with_mglru=False)

            def failing_runner(_cmd: caboose_memory.Sequence[str]) -> int:
                return 1

            setup_res = caboose_memory.setup(root=root, runner=failing_runner)
            self.assertFalse(setup_res['zram']['configured'])
            self.assertFalse(setup_res['mglru']['supported'])

            reclaim_res = caboose_memory.reclaim(
                mode='pressure',
                root=root,
                sync_fn=lambda: None,
            )
            self.assertEqual(reclaim_res['mode'], 'pressure')
            self.assertIsNone(reclaim_res['zram']['after'])


if __name__ == '__main__':
    unittest.main()

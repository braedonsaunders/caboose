#!/usr/bin/env python3
"""Retain at most the last 2 MiB of each hosted build/test log before artifact upload."""
from pathlib import Path

limit = 2 * 1024 * 1024
for log in Path('.gpu-check-logs').glob('*.log'):
    if log.stat().st_size > limit:
        with log.open('rb') as stream:
            prefix = b'[earlier output omitted; see hosted job log]\n'
            stream.seek(-(limit - len(prefix)), 2)
            tail = stream.read()
        log.write_bytes(prefix + tail)

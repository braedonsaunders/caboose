#!/usr/bin/env python3
"""Summarise benchmark records as Markdown: totals per set and mode, then each task.

usage: summarize.py RECORDS.jsonl ...

Each file holds run.py's records (one JSON line per task run); runs of the same mode are
pooled. Sets: the single-application tasks, the `flow-` workflows and the `direct-` tasks."""
import json
import statistics as st
import sys
from collections import defaultdict

rows = [json.loads(line) for path in sys.argv[1:] for line in open(path) if line.strip()]
if not rows:
    sys.exit(__doc__)


def kind(task):
    return 'workflows' if task.startswith('flow-') else 'direct' if task.startswith('direct-') else 'single-app'


def line(records):
    seconds = [r.get('seconds', 0) for r in records]
    return (f"{sum(r['success'] for r in records)}/{len(records)} | {st.mean(seconds):.1f} / {st.median(seconds):.1f} | "
            f"{st.mean(r.get('toolCalls', 0) for r in records):.1f} | {st.mean(r.get('inputTokens', 0) for r in records) / 1000:.0f}k | "
            f"{st.mean((r.get('costUsd') or 0) for r in records):.3f}")


modes = sorted({r['mode'] for r in rows})
print('| Set | Mode | Success | Mean / median s | Calls | Input tokens | $/task |')
print('|---|---|---|---|---|---|---|')
for name in ('single-app', 'workflows', 'direct'):
    for mode in modes:
        records = [r for r in rows if r['mode'] == mode and kind(r['task']) == name]
        if records:
            tasks = len({r['task'] for r in records})
            print(f'| {tasks} {name} | {mode} | {line(records)} |')
print()
print('| Task | ' + ' | '.join(f'{m}: ok, s, calls' for m in modes) + ' |')
print('|---|' + '---|' * len(modes))
by_task = defaultdict(lambda: defaultdict(list))
for r in rows:
    by_task[r['task']][r['mode']].append(r)
for task, per_mode in by_task.items():
    cells = []
    for mode in modes:
        records = per_mode.get(mode, [])
        cells.append(f"{sum(r['success'] for r in records)}/{len(records)}, {st.mean(r.get('seconds', 0) for r in records):.0f}, "
                     f"{st.mean(r.get('toolCalls', 0) for r in records):.0f}" if records else '—')
    print(f'| {task} | ' + ' | '.join(cells) + ' |')

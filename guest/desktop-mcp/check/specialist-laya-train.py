#!/usr/bin/env python3
"""Fine-tune the licensed Laya decision head on explicit fixture option labels."""
import argparse
import json
import time
from pathlib import Path
import torch
from laya.train import TrainConfig, finetune, to_internal, load_checkpoint
from laya.common import build_sequence

p = argparse.ArgumentParser()
p.add_argument('--model', required=True)
p.add_argument('--data', required=True)
p.add_argument('--validation', required=True)
p.add_argument('--output', required=True)
p.add_argument('--device', choices=['cpu', 'mps', 'cuda'], default='mps')
a = p.parse_args()
torch.set_num_threads(4)
if a.device == 'mps': torch.mps.set_per_process_memory_fraction(0.2)
if a.device == 'cuda': torch.cuda.set_per_process_memory_fraction(0.6)
schema = json.loads(Path(__file__).with_name('specialist-decision-schema.json').read_text())
output = Path(a.output)
output.mkdir(exist_ok=False, parents=True)
# Preflight token budgets: upstream can truncate, but truncated supervision is not accepted here.
model, tokenizer, _ = load_checkpoint(a.model)
del model
for source, name in [(a.data, 'train'), (a.validation, 'validation')]:
    rows = []
    for line in Path(source).read_text().splitlines():
        record = json.loads(line)
        question = {'type': 'choice', 'instructions': schema['instructions'], 'criteria': {str(i): c for i, c in enumerate(record['choices'])}}
        internal = to_internal('next', question)
        _, _, options, truncation = build_sequence(tokenizer, record['state'], internal, max_len=1024, head_max_len=768, return_stats=True, return_truncation_stats=True)
        if truncation['truncated'] or options['tokens_per_option'] is not None or options['options_distinct'] != len(record['choices']):
            raise ValueError(f'{name} contains a truncated or collapsed observation')
        acceptable = record.get('acceptable', [record['expected']])
        rows.append({'state': record['state'], 'questions': {'next': question}, 'gold': {'next': {'probabilities': {str(i): 1 / len(acceptable) for i in acceptable}}}})
    (output / f'{name}.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in rows))
del tokenizer
config = TrainConfig(epochs=2, micro_batch=2, grad_accum=4, freeze_encoder=True, head_lr=0.0001,
                     loss='soft-ce', shuffle_options=('choice',), seed=42, max_len=1024, head_max_len=768,
                     calib_max=200, calib_frac=0.1, gradient_checkpointing=True, log_every=20,
                     eval_data=str(output / 'validation.jsonl'))
started = time.perf_counter()
report = finetune(str(output / 'train.jsonl'), a.model, str(output / 'checkpoint'), config, device=a.device)
report['measured_seconds'] = time.perf_counter() - started
report['device'] = a.device
report['torch_version'] = torch.__version__
if a.device == 'cuda':
    report['device_name'] = torch.cuda.get_device_name()
    report['peak_allocated_bytes'] = torch.cuda.max_memory_allocated()
(output / 'run.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report), flush=True)

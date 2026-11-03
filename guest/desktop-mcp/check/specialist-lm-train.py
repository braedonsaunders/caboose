#!/usr/bin/env python3
"""Fully fine-tune a small causal LM to answer choices.mjs's decision prompt with one letter.

Only the answer position is supervised: the target is spread evenly over every acceptable
choice, so any order the task allows is correct. Writes a Hugging Face checkpoint that
`mlx_lm.convert` quantizes for the phone and Mac runtimes.
"""
import argparse
import json
import math
import random
import time
from pathlib import Path
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer
LETTERS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef'  # choices.mjs decisionPrompt

p = argparse.ArgumentParser()
p.add_argument('--model', required=True)
p.add_argument('--data', required=True)
p.add_argument('--validation', required=True)
p.add_argument('--output', required=True)
p.add_argument('--epochs', type=int, default=2)
p.add_argument('--batch', type=int, default=16)
p.add_argument('--lr', type=float, default=2e-5)
p.add_argument('--seed', type=int, default=42)
a = p.parse_args()
torch.manual_seed(a.seed)
random.seed(a.seed)
torch.set_num_threads(4)
torch.cuda.set_per_process_memory_fraction(0.75)
output = Path(a.output)
output.mkdir(parents=True, exist_ok=False)
tokenizer = AutoTokenizer.from_pretrained(a.model)
letters = [tokenizer.encode(' ' + letter, add_special_tokens=False) for letter in LETTERS]
assert all(len(ids) == 1 for ids in letters)
letters = torch.tensor([ids[0] for ids in letters]).cuda()


def rows(path):
    out = []
    for line in Path(path).read_text().splitlines():
        r = json.loads(line)
        ids = tokenizer.encode(r['prompt'], add_special_tokens=False)
        if len(ids) > 2048: raise ValueError(f'{path}: prompt exceeds 2048 tokens')
        out.append((ids, len(r['choices']), r.get('acceptable', [r['expected']]), r['kind']))
    return out


train, validation = rows(a.data), rows(a.validation)
model = AutoModelForCausalLM.from_pretrained(a.model, dtype=torch.float32).cuda()
model.gradient_checkpointing_enable()
model.config.use_cache = False
optimizer = torch.optim.AdamW(model.parameters(), lr=a.lr, weight_decay=0.01)
steps = a.epochs * math.ceil(len(train) / a.batch)
schedule = torch.optim.lr_scheduler.LambdaLR(optimizer, lambda s: min(1, (s + 1) / 30) * max(0.0, 1 - s / steps))


def batch_logits(batch):
    width = max(len(ids) for ids, *_ in batch)
    pad = tokenizer.pad_token_id or 0
    input_ids = torch.tensor([ids + [pad] * (width - len(ids)) for ids, *_ in batch]).cuda()
    mask = torch.tensor([[1] * len(ids) + [0] * (width - len(ids)) for ids, *_ in batch]).cuda()
    with torch.autocast('cuda', dtype=torch.bfloat16):
        hidden = model.model(input_ids=input_ids, attention_mask=mask).last_hidden_state
    last = hidden[torch.arange(len(batch)), mask.sum(1) - 1]
    return model.lm_head(last.to(model.lm_head.weight.dtype)).float()


def evaluate(data):
    model.eval()
    correct, by_kind = 0, {}
    with torch.no_grad():
        for start in range(0, len(data), 32):
            batch = data[start:start + 32]
            logits = batch_logits(batch)[:, letters]
            for row, (_, n, acceptable, kind) in zip(logits, batch):
                ok = int(row[:n].argmax()) in acceptable
                correct += ok
                hit, total = by_kind.get(kind, (0, 0)); by_kind[kind] = (hit + ok, total + 1)
    model.train()
    return correct / len(data), {k: f'{h}/{t}' for k, (h, t) in sorted(by_kind.items())}


report = {'train_rows': len(train), 'validation_rows': len(validation), 'epochs': a.epochs, 'batch': a.batch, 'lr': a.lr, 'seed': a.seed,
          'model': a.model, 'device': torch.cuda.get_device_name(), 'torch': torch.__version__}
report['before'] = evaluate(validation)
print('before', report['before'], flush=True)
started, step = time.perf_counter(), 0
model.train()
for epoch in range(a.epochs):
    order = list(range(len(train))); random.shuffle(order)
    total = 0.0
    for start in range(0, len(order), a.batch):
        batch = [train[i] for i in order[start:start + a.batch]]
        log_probs = torch.log_softmax(batch_logits(batch), -1)
        loss = torch.stack([-log_probs[i, letters[acceptable]].mean() for i, (_, _, acceptable, _) in enumerate(batch)]).mean()
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        optimizer.step(); schedule.step(); optimizer.zero_grad(set_to_none=True)
        total += loss.item() * len(batch); step += 1
        if step % 50 == 0: print(f'epoch {epoch + 1} step {step}/{steps} loss {loss.item():.4f}', flush=True)
    report.setdefault('epoch_loss', []).append(total / len(train))
    report.setdefault('validation', []).append(evaluate(validation))
    print('epoch', epoch + 1, report['epoch_loss'][-1], report['validation'][-1], flush=True)
report['train_seconds'] = time.perf_counter() - started
report['peak_allocated_bytes'] = torch.cuda.max_memory_allocated()
model.config.use_cache = True
model.to(torch.bfloat16).save_pretrained(output / 'checkpoint', safe_serialization=True)
tokenizer.save_pretrained(output / 'checkpoint')
(output / 'run.json').write_text(json.dumps(report, indent=2))
print(json.dumps(report), flush=True)

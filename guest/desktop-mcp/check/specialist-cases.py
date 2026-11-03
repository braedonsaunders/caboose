#!/usr/bin/env python3
"""Generate disjoint fixture vocabularies/layout seeds, not private task examples."""
import argparse
import json
import random
p = argparse.ArgumentParser()
p.add_argument('--split', choices=['train', 'validation', 'heldout'], required=True)
p.add_argument('--count', type=int, default=20)
p.add_argument('--output', required=True)
a = p.parse_args()
assert 1 <= a.count <= 1000
seed = {'train': 42, 'validation': 1701, 'heldout': 9001}[a.split]
rng = random.Random(seed)
vocabulary = {
    'train': [('Title', 'Summary', 'Enable alerts', 'Apply', 'Applied', 'Reset all'), ('Name', 'Note', 'Keep copy', 'Save', 'Saved', 'Discard')],
    'validation': [('Label', 'Description', 'Allow reminder', 'Store', 'Stored', 'Clear')],
    'heldout': [('Destination', 'Reference', 'Keep receipt', 'Commit', 'Completed', 'Reset'), ('Subject', 'Details', 'Enable notice', 'Confirm', 'Confirmed', 'Cancel')],
}[a.split]
cases = []
for i in range(a.count):
    first, second, toggle, submit, complete, distractor = vocabulary[i % len(vocabulary)]
    fields = [{'name': first, 'value': f'{a.split} record {rng.randrange(1000, 9999)}'}, {'name': second, 'value': f'item {rng.randrange(1000, 9999)}'}]
    if a.split == 'heldout': fields.append({'name': 'Routing code', 'value': f'route {rng.randrange(100, 999)}'})
    order = list(range(len(fields) + 3)); rng.shuffle(order)
    objective = "; ".join(f"Set {f['name']} to {f['value']}" for f in fields) + f"; check {toggle}, then press {submit}."
    cases.append(dict(split=a.split, seed=seed, fields=fields, toggle=toggle, submit=submit, complete=complete,
                      distractor=distractor, order=order, objective=objective, goal={'name': complete, 'role': 'button'}))
with open(a.output, 'w') as f: json.dump(cases, f, indent=2)

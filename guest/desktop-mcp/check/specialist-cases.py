#!/usr/bin/env python3
"""Generate disjoint fixture vocabularies/layout seeds, not private task examples."""
import argparse
import json
import random
p = argparse.ArgumentParser()
p.add_argument('--split', choices=['train', 'validation', 'heldout', 'fresh'], required=True)
p.add_argument('--count', type=int, default=20)
p.add_argument('--output', required=True)
p.add_argument('--varied', action='store_true', help='train/validation use 1–4 fields; heldout uses new 0/5-field families')
p.add_argument('--generated', action='store_true', help='draw every case from disjoint per-split label pools and phrasings')
a = p.parse_args()
assert 1 <= a.count <= 1000
assert a.split != 'fresh' or a.generated, 'the fresh split exists only as generated families'

# Labels are disjoint across splits, so a model can only succeed by reading the objective;
# fresh also has its own phrasings and value formats.
POOLS = {
    'train': dict(
        fields=['Title', 'Summary', 'Name', 'Note', 'Category', 'Tracking number', 'Group', 'City', 'Street', 'Postcode', 'Phone',
                'Email', 'Company', 'Job title', 'Username', 'Nickname', 'Website', 'Project', 'Task', 'Owner', 'Priority', 'Budget',
                'Quantity', 'Price', 'Discount', 'Invoice number', 'Order number', 'Account', 'Branch', 'Region', 'Country', 'Language',
                'Comment', 'Message', 'Headline', 'Keywords', 'Author', 'Publisher', 'Edition', 'Room', 'Floor', 'Building', 'Vehicle',
                'Plate number', 'Model', 'Serial number', 'Version', 'Milestone', 'Folder', 'File name', 'Tag', 'Color', 'Size', 'Weight'],
        toggles=['Enable alerts', 'Keep copy', 'Remember me', 'Send newsletter', 'Accept terms', 'Use defaults', 'Show preview',
                 'Mark urgent', 'Notify team', 'Include archive', 'Auto renew', 'Share publicly', 'Track changes', 'Lock record',
                 'Enable sync', 'Print summary', 'Save draft', 'Pin item'],
        actions=[('Apply', 'Applied'), ('Save', 'Saved'), ('Submit', 'Submitted'), ('Send', 'Sent'), ('Create', 'Created'),
                 ('Update', 'Updated'), ('Register', 'Registered'), ('Publish', 'Published'), ('Add', 'Added'), ('Book', 'Booked'),
                 ('Upload', 'Uploaded'), ('Approve', 'Approved'), ('Finish', 'Finished'), ('Continue', 'Continued')],
        distractors=['Reset all', 'Discard', 'Delete', 'Close', 'Back', 'Help', 'Undo', 'Remove', 'Abort', 'Revert'],
        set=['Set {name} to {value}', 'Enter {value} in {name}', 'Fill {name} with {value}', 'Type {value} into {name}',
             '{name} should be {value}', 'Change {name} to {value}'],
        check=['check {toggle}', 'tick {toggle}', 'turn on {toggle}', 'select {toggle}'],
        press=['then press {submit}', 'then click {submit}', 'and finish with {submit}', 'then use {submit}'],
        values=['{word} {n4}', '{n4}-{n3}', '{word}{n3}', '{word} {word2}', 'no. {n4}', '{n3} {word} lane']),
    'validation': dict(
        fields=['Label', 'Description', 'Section', 'Batch number', 'Topic', 'Venue', 'Course', 'Grade', 'Mentor', 'Studio',
                'Channel', 'Genre', 'Season', 'Episode', 'Station'],
        toggles=['Allow reminder', 'Hide details', 'Request receipt', 'Keep history', 'Enable captions', 'Join waitlist'],
        actions=[('Store', 'Stored'), ('Post', 'Posted'), ('Schedule', 'Scheduled'), ('Enroll', 'Enrolled'), ('Assign', 'Assigned')],
        distractors=['Clear', 'Dismiss', 'Skip', 'Erase'],
        set=['Set {name} to {value}', 'Enter {value} in {name}', 'Fill {name} with {value}'],
        check=['check {toggle}', 'tick {toggle}'],
        press=['then press {submit}', 'then click {submit}'],
        values=['{word} {n4}', '{n4}-{n3}', '{word}{n3}']),
    'fresh': dict(
        fields=['Harbor', 'Cargo class', 'Vessel name', 'Berth', 'Manifest code', 'Recipe', 'Ingredient', 'Oven mode', 'Planet',
                'Orbit', 'Telescope', 'Species', 'Habitat', 'Herd size', 'Instrument', 'Tempo', 'Composer'],
        toggles=['Sound horn', 'Chill storage', 'Track orbit', 'Tag animal', 'Loop melody', 'Seal hatch'],
        actions=[('Dispatch', 'Dispatched'), ('Launch', 'Launched'), ('Bake', 'Baked'), ('Release', 'Released'), ('Record', 'Recorded')],
        distractors=['Scrap', 'Wipe', 'Halt', 'Purge'],
        set=['Put {value} as {name}', '{name} needs {value}', 'Use {value} for {name}'],
        check=['enable {toggle}', 'make sure {toggle} is on'],
        press=['and lastly hit {submit}', 'then activate {submit}'],
        values=['{word}-{n3}', '{n3}.{n3b}', '{word} {word2} {n3}']),
}
WORDS = {'train': ['amber', 'birch', 'cobalt', 'delta', 'ember', 'falcon', 'garnet', 'hazel', 'indigo', 'juniper', 'kestrel', 'lumen'],
         'validation': ['maple', 'nimbus', 'onyx', 'pepper', 'quartz'],
         'fresh': ['raven', 'saffron', 'tundra', 'umber', 'violet']}

def generated_case(rng, split, index):
    pool, words = POOLS[split], WORDS[split]
    count = index % 6
    names = rng.sample(pool['fields'], count)
    def value():
        return rng.choice(pool['values']).format(word=rng.choice(words).capitalize(), word2=rng.choice(words), n4=rng.randrange(1000, 9999), n3=rng.randrange(100, 999), n3b=rng.randrange(100, 999))
    fields = [{'name': name, 'value': value()} for name in names]
    toggle = rng.choice(pool['toggles'])
    submit, complete = rng.choice(pool['actions'])
    distractor = rng.choice(pool['distractors'])
    order = list(range(len(fields) + 3)); rng.shuffle(order)
    steps = [rng.choice(pool['set']).format(name=f['name'], value=f['value']) for f in fields]
    steps.append(rng.choice(pool['check']).format(toggle=toggle))
    objective = '; '.join(steps) + ', ' + rng.choice(pool['press']).format(submit=submit) + '.'
    return dict(split=split, seed=None, fields=fields, toggle=toggle, submit=submit, complete=complete, distractor=distractor,
                order=order, objective=objective[0].upper() + objective[1:], goal={'name': complete, 'role': 'button'})

if a.generated:
    seed = {'train': 42, 'validation': 1701, 'fresh': 31337}[a.split] + 20000
    rng = random.Random(seed)
    cases = [dict(generated_case(rng, a.split, i), seed=seed) for i in range(a.count)]
    with open(a.output, 'w') as f: json.dump(cases, f, indent=2)
    raise SystemExit
seed = {'train': 42, 'validation': 1701, 'heldout': 9001}[a.split]
if a.varied: seed += 10000
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
    if a.varied:
        count = (0 if i % 2 == 0 else 5) if a.split == 'heldout' else 1 + i % 4
        extra = {'train': ['Category', 'Tracking number', 'Group'], 'validation': ['Section', 'Batch number', 'Topic'], 'heldout': ['Routing code', 'Department', 'Contact tag']}[a.split]
        labels = [first, second, *extra]
        fields = [{'name': name, 'value': f'{a.split} value {rng.randrange(1000, 9999)}'} for name in labels[:count]]
    order = list(range(len(fields) + 3)); rng.shuffle(order)
    objective = "; ".join(f"Set {f['name']} to {f['value']}" for f in fields) + f"; check {toggle}, then press {submit}."
    cases.append(dict(split=a.split, seed=seed, fields=fields, toggle=toggle, submit=submit, complete=complete,
                      distractor=distractor, order=order, objective=objective, goal={'name': complete, 'role': 'button'}))
with open(a.output, 'w') as f: json.dump(cases, f, indent=2)

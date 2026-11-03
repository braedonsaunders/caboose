#!/usr/bin/env python3
"""Generate real-application tasks (Mousepad, Thunar) for training and held-out evaluation.

Each case names the application to launch with files to create first, an objective, an
observable goal, literal value sources, an oracle (the choice labels a correct run presses,
in order, as regular expressions) and an independent check of the effect. Splits use disjoint
names and options; the holdout adds a task family training never sees (`thunar-open`).
"""
import argparse
import json
import random

p = argparse.ArgumentParser()
p.add_argument('--split', choices=['train', 'validation', 'holdout'], required=True)
p.add_argument('--count', type=int, default=40)
p.add_argument('--output', required=True)
a = p.parse_args()
assert 1 <= a.count <= 500
rng = random.Random({'train': 7, 'validation': 77, 'holdout': 777}[a.split])
HOME = '/tmp/specialist-home'
WORDS = {'train': ['harvest', 'lantern', 'meadow', 'orbit', 'pebble', 'quill', 'ripple', 'summit'],
         'validation': ['tundra', 'violet', 'willow'], 'holdout': ['zephyr', 'yonder', 'xylem', 'cobble']}[a.split]
# Mousepad preference check boxes that start unchecked, by tab; split so holdout options are unseen.
OPTIONS = {'train': [('View', 'Show line numbers'), ('View', 'Display whitespace'), ('Editor', 'Enable automatic indentation')],
           'validation': [('View', 'Highlight current line')],
           'holdout': [('View', 'Display line endings'), ('View', 'Highlight matching brackets'), ('View', 'Wrap long lines')]}[a.split]
SAVE_PHRASES = {'train': ['Write "{text}" into the document and save it as {name}.', 'Replace the text with "{text}", then save the file as {name}.'],
                'validation': ['Put "{text}" in the document and use Save As to call it {name}.'],
                'holdout': ['Make the document say "{text}" and store it under the name {name}.']}[a.split]
PREF_PHRASES = {'train': ['In Mousepad preferences, turn on {option}.', 'Enable the {option} setting in the preferences.'],
                'validation': ['Open the preferences and switch on {option}.'],
                'holdout': ['Make sure {option} is enabled in Mousepad\'s settings.']}[a.split]


def word():
    return rng.choice(WORDS)


def save_as(i):
    text = f'{word()} {rng.randrange(100, 999)} {word()}'
    name = f'{word()}-{rng.randrange(10, 99)}.txt'
    return {'family': 'mousepad-save-as', 'app': 'mousepad', 'args': [f'{HOME}/Documents/notes.txt'],
            'files': {'Documents/notes.txt': 'hello\n'}, 'objective': rng.choice(SAVE_PHRASES).format(text=text, name=name),
            'values': [{'name': 'document text', 'value': text}, {'name': 'file name', 'value': name}],
            'goal': {'title': f'~/Documents/{name} - Mousepad'},
            'oracle': [rf'^SET text from .* to "{text}"', r'^PRESS File \(menu\)$', r'^PRESS Save As\.\.\. \(menu item\)$',
                       rf'^SET Name from .* to "{name}"', r'^PRESS Save \(button\)$'],
            'check': {'file': f'Documents/{name}', 'content': text}}


def preference(i):
    tab, option = OPTIONS[i % len(OPTIONS)]
    oracle = [r'^PRESS Edit \(menu\)$', r'^PRESS Preferences\.\.\. \(menu item\)$']
    if tab != 'View':
        oracle.append(rf'^PRESS {tab} \(page tab\)$')
    oracle.append(rf'^PRESS {option} \(check box, not checked\)$')
    return {'family': 'mousepad-preference', 'app': 'mousepad', 'args': [f'{HOME}/Documents/notes.txt'],
            'files': {'Documents/notes.txt': 'hello\n'}, 'objective': rng.choice(PREF_PHRASES).format(option=option),
            'values': [], 'goal': {'name': option, 'role': 'check box', 'state': 'checked'}, 'oracle': oracle, 'check': None}


def thunar_open(i):
    parent, child = rng.choice(['Projects', 'Archive', 'Shared']), f'{word().capitalize()}{rng.randrange(1, 9)}'
    path = f'{HOME}/Documents/{parent}/{child}'
    return {'family': 'thunar-open', 'app': 'thunar', 'args': [f'{HOME}/Documents'], 'files': {f'Documents/{parent}/{child}/.keep': ''},
            'objective': f'Open the folder {path} in the file manager.', 'values': [{'name': 'folder', 'value': path}],
            'goal': {'title': f'{child} - Thunar'}, 'oracle': [rf'^SET text from .* to "{path}"', r'^PRESS text \(text\)$'], 'check': None}


families = [save_as, preference] + ([thunar_open] if a.split == 'holdout' else [])
cases = [dict(families[i % len(families)](i), split=a.split) for i in range(a.count)]
with open(a.output, 'w') as f:
    json.dump(cases, f, indent=1)

#!/usr/bin/env python3
"""Generate real-application tasks (Mousepad, Thunar, Chromium pages) for training and held-out evaluation.

Each case names the application to launch with files to create first, an objective, an
observable goal, literal value sources, an oracle (the choice labels a correct run presses,
in order, as regular expressions) and an independent check of the effect. Splits use disjoint
names, folders, phrasings and options; `holdout2` is kept for one final measurement, and
`unseen` holds task families absent from every training split.
"""
import argparse
import html
import json
import random

p = argparse.ArgumentParser()
p.add_argument('--split', choices=['train', 'validation', 'holdout', 'holdout2', 'unseen'], required=True)
p.add_argument('--count', type=int, default=40)
p.add_argument('--output', required=True)
a = p.parse_args()
assert 1 <= a.count <= 500
rng = random.Random({'train': 7, 'validation': 77, 'holdout': 777, 'holdout2': 7777, 'unseen': 77777}[a.split])
HOME = '/tmp/specialist-home'
WORDS = {'train': ['harvest', 'lantern', 'meadow', 'orbit', 'pebble', 'quill', 'ripple', 'summit'],
         'validation': ['tundra', 'violet', 'willow'], 'holdout': ['zephyr', 'yonder', 'xylem', 'cobble'],
         'holdout2': ['basalt', 'cinder', 'drift', 'fjord'], 'unseen': ['granite', 'heron', 'iris', 'jasper']}[a.split]
# Mousepad preference check boxes that start unchecked, by tab; split so holdout options are unseen.
OPTIONS = {'train': [('View', 'Show line numbers'), ('View', 'Display whitespace'), ('Editor', 'Enable automatic indentation')],
           'validation': [('View', 'Highlight current line')],
           'holdout': [('View', 'Display line endings'), ('View', 'Highlight matching brackets'), ('View', 'Wrap long lines')]}.get(
               a.split, [('View', 'Display line endings'), ('View', 'Highlight matching brackets'), ('View', 'Wrap long lines')])
SAVE_PHRASES = {'train': ['Write "{text}" into the document and save it as {name}.', 'Replace the text with "{text}", then save the file as {name}.',
                          'Write "{text}" and choose Save As to store it as {name}.'],
                'validation': ['Put "{text}" in the document and use Save As to call it {name}.'],
                'holdout': ['Make the document say "{text}" and store it under the name {name}.'],
                'holdout2': ['Type "{text}" as the whole document, then save a copy named {name}.']}.get(a.split, ['Write "{text}" into the document and save it as {name}.'])
PREF_PHRASES = {'train': ['In Mousepad preferences, turn on {option}.', 'Enable the {option} setting in the preferences.'],
                'validation': ['Open the preferences and switch on {option}.'],
                'holdout': ['Make sure {option} is enabled in Mousepad\'s settings.'],
                'holdout2': ['Go into the editor settings and tick {option}.']}.get(a.split, ['In Mousepad preferences, turn on {option}.'])


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


FOLDERS = {'train': ['Clients', 'Reports', 'Media', 'Invoices'], 'validation': ['Drafts'], 'holdout': ['Projects', 'Archive', 'Shared'],
           'holdout2': ['Library', 'Workshop'], 'unseen': ['Studio', 'Garage']}[a.split]
OPEN_PHRASES = {'train': ['Open the folder {path} in the file manager.', 'Go to {path} in Thunar.'], 'validation': ['Show the folder {path}.'],
                'holdout': ['Open the folder {path} in the file manager.'], 'holdout2': ['Navigate the file manager to {path}.']}.get(a.split, ['Open the folder {path} in the file manager.'])
# Web pages (Chromium, accessibility forced on): labels, buttons and titles per split.
WEB = {'train': dict(fields=['Recipient', 'City', 'Street', 'Phone', 'Email', 'Company', 'Order number', 'Comment', 'Coupon', 'Seat'],
                     boxes=['Gift wrap', 'Express delivery', 'Subscribe', 'Accept terms', 'Remember me'],
                     submits=[('Ship order', 'Shipped'), ('Book now', 'Booked'), ('Send message', 'Sent'), ('Register', 'Registered')],
                     distractors=['Reset', 'Cancel', 'Back'], phrases=['On the web page, {steps}, then press {submit}.', 'Fill the page: {steps}; finish with {submit}.']),
       'validation': dict(fields=['Venue', 'Guest name', 'Table'], boxes=['Vegetarian'], submits=[('Reserve', 'Reserved')], distractors=['Clear'],
                          phrases=['In the browser, {steps}, then press {submit}.']),
       'holdout2': dict(fields=['Badge', 'Team', 'Locker'], boxes=['Night shift'], submits=[('Enroll', 'Enrolled')], distractors=['Discard'],
                        phrases=['Use the open page to {steps}; then hit {submit}.']),
       'unseen': dict(fields=['Plot', 'Crop', 'Acres'], boxes=['Organic', 'Irrigated', 'Fenced', 'Insured'], submits=[('File claim', 'Claimed'), ('Register plot', 'Registered')], distractors=['Abort', 'Clear'],
                              phrases=['On the site, {steps}, then submit with {submit}.'])}.get(a.split)
FIND_PHRASES = ['Replace every "{old}" with "{new}" in the document using Find and Replace.']
# Thunar Preferences check boxes that start unchecked and do not change how Thunar opens or titles windows.
THUNAR_OPTIONS = [('Display', 'Draw frames around thumbnails'), ('Display', 'Text beside icons'), ('Side Pane', 'Use symbolic folder icons')]


def find_replace(i):
    old, new = word(), word() + 'x'
    while new.startswith(old): new = word() + 'x'
    body = f'the {old} and the {old} again'
    return {'family': 'mousepad-find-replace', 'app': 'mousepad', 'args': [f'{HOME}/Documents/notes.txt'], 'files': {'Documents/notes.txt': body + '\n'},
            'objective': rng.choice(FIND_PHRASES).format(old=old, new=new),
            'values': [{'name': 'Search for', 'value': old}, {'name': 'Replace with', 'value': new}], 'goal': None,
            'oracle': [r'^PRESS Search \(menu\)$', r'^PRESS Find and Replace\.\.\. \(menu item\)$', rf'^SET Search for: from .* to "{old}"$', rf'^SET Replace with: from .* to "{new}"$',
                       r'^PRESS Replace all in: \(check box, not checked\)$', r'^PRESS Replace( All)? \(button\)$'],
            'check': None}


# Chromium pages offer presses only: text typed into a Chromium field does not reach it on the
# agent seat (no EditableText, and seat keys are not delivered to its renderer).
def web_page(title, boxes, wanted, submit, complete, distractor):
    checks = ' && '.join(f"document.getElementById('b{k}').checked === {'true' if b in wanted else 'false'}" for k, b in enumerate(boxes))
    inputs = ''.join(f'<p><label><input type="checkbox" id="b{k}"> {b}</label></p>' for k, b in enumerate(boxes))
    handler = html.escape(f"event.preventDefault(); document.title = ({checks}) ? {json.dumps(complete)} : 'Incomplete';")
    form = (f'<form onsubmit="{handler}">{inputs}'
            f'<button type="button">{distractor}</button> <button type="submit">{submit}</button></form>')
    return f'<!doctype html><html><head><title>{title}</title></head><body><h1>{title}</h1>{form}</body></html>'


def web_case(family, files, start, objective, oracle, complete):
    return {'family': family, 'app': '/usr/bin/chromium', 'app_id': 'Chromium', 'args': ['--force-renderer-accessibility', '--no-first-run', '--no-default-browser-check',
            f'--user-data-dir={HOME}/chromium', '--new-window', f'file://{HOME}/Documents/{start}'], 'files': files,
            'objective': objective, 'values': [], 'goal': {'title': f'{complete} - Chromium'}, 'oracle': oracle, 'check': None}


def web_choices():
    boxes = rng.sample(WEB['boxes'], len(WEB['boxes']))
    wanted = boxes[:1 + rng.randrange(min(2, len(boxes)))]
    (submit, complete), distractor = rng.choice(WEB['submits']), rng.choice(WEB['distractors'])
    return boxes, wanted, submit, complete, distractor


def web_form(i):
    boxes, wanted, submit, complete, distractor = web_choices()
    page = web_page(f'{word().capitalize()} form', boxes, wanted, submit, complete, distractor)
    steps = ' and '.join(f'tick {b}' for b in wanted)
    return web_case('chromium-form', {'Documents/page.html': page}, 'page.html', rng.choice(WEB['phrases']).format(steps=steps, submit=submit),
                    [rf'^PRESS {b} \(check box, not checked\)$' for b in wanted] + [rf'^PRESS {submit} \(button\)$'], complete)


def web_two_page(i):
    boxes, wanted, submit, complete, distractor = web_choices()
    link = 'Continue to the form'
    start = f'<!doctype html><html><head><title>Welcome</title></head><body><h1>Welcome</h1><p><a href="form.html">{link}</a></p><p><a href="help.html">Help</a></p></body></html>'
    steps = ' and '.join(f'tick {b}' for b in wanted)
    return web_case('chromium-two-page', {'Documents/start.html': start, 'Documents/form.html': web_page('Details', boxes, wanted, submit, complete, distractor)}, 'start.html',
                    f'Follow "{link}", then {steps}, and submit with {submit}.',
                    [rf'^PRESS {link} \(link\)$'] + [rf'^PRESS {b} \(check box, not checked\)$' for b in wanted] + [rf'^PRESS {submit} \(button\)$'], complete)


def thunar_create(i):
    name = f'{word().capitalize()}{rng.randrange(10, 99)}'
    return {'family': 'thunar-create-folder', 'app': 'thunar', 'args': [f'{HOME}/Documents'], 'files': {'Documents/.keep': ''},
            'objective': f'Create a new folder named {name} in this folder.', 'values': [{'name': 'folder name', 'value': name}], 'goal': None,
            'oracle': [r'^PRESS File \(menu\)$', r'^PRESS Create Folder\.\.\. \(menu item\)$', rf'^SET .* to "{name}"', r'^PRESS Create \(button\)$'],
            'check': {'dir': f'Documents/{name}'}}


def thunar_preference(i):
    tab, option = THUNAR_OPTIONS[i % len(THUNAR_OPTIONS)]
    oracle = ([] if tab == 'Display' else [rf'^PRESS {tab} \(page tab\)$']) + [rf'^PRESS {option} \(check box, not checked\)$']
    return {'family': 'thunar-preference', 'app': 'thunar-settings', 'app_id': 'Thunar', 'args': [], 'files': {},
            'objective': f'In the file manager preferences, turn on {option}.', 'values': [],
            'goal': {'name': option, 'role': 'check box', 'state': 'checked'}, 'oracle': oracle, 'check': None,
            'reset': ['xfconf-query', '-c', 'thunar', '-r', '-R', '-p', '/']}


def thunar_open(i):
    parent, child = rng.choice(FOLDERS), f'{word().capitalize()}{rng.randrange(1, 9)}'
    path = f'{HOME}/Documents/{parent}/{child}'
    return {'family': 'thunar-open', 'app': 'thunar', 'args': [f'{HOME}/Documents'], 'files': {f'Documents/{parent}/{child}/.keep': ''},
            'objective': rng.choice(OPEN_PHRASES).format(path=path), 'values': [{'name': 'folder', 'value': path}],
            'goal': {'title': f'{child} - Thunar'}, 'oracle': [rf'^SET text from .* to "{path}"', r'^PRESS text \(text\)$'], 'check': None}


# `unseen`: task families no model was trained on (new applications, dialogs and task types).
families = [thunar_create, thunar_preference, web_form, web_two_page, find_replace] if a.split == 'unseen' else [save_as, preference, thunar_open]
cases = [dict(families[i % len(families)](i), split=a.split) for i in range(a.count)]
with open(a.output, 'w') as f:
    json.dump(cases, f, indent=1)

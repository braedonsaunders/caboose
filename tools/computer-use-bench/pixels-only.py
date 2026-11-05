#!/usr/bin/env python3
"""MCP stdio proxy for the screenshot baseline: runs the computer-use server command given as
arguments and offers the agent screenshot computer use only. Its tools are the usual
screenshot, pointer and keyboard ones (screenshot, list_windows, focus, click, drag, type,
key, scroll, and launch to start an application), each carried out as one computer-use act step whose reply is cut to "Done." or the
error, so no accessibility data reaches the agent."""
import json
import subprocess
import sys
import threading

point = {'type': 'integer'}
TOOLS = [
    {'name': 'screenshot', 'description': 'A picture of the seat, or of one window. Coordinates in other tools are its pixels.',
     'inputSchema': {'type': 'object', 'properties': {'window': point}}},
    {'name': 'list_windows', 'description': 'The open windows: id, kind, title, app and position (x,y,width,height).',
     'inputSchema': {'type': 'object', 'properties': {}}},
    {'name': 'focus', 'description': 'Raise and focus a window by id.', 'inputSchema': {'type': 'object', 'properties': {'window': point}, 'required': ['window']}},
    {'name': 'click', 'description': 'Click at (x, y). button: 1 left, 2 middle, 3 right; count 2 for a double click.',
     'inputSchema': {'type': 'object', 'properties': {'x': point, 'y': point, 'button': point, 'count': point}, 'required': ['x', 'y']}},
    {'name': 'drag', 'description': 'Press at (x1, y1), move to (x2, y2), release.',
     'inputSchema': {'type': 'object', 'properties': {'x1': point, 'y1': point, 'x2': point, 'y2': point}, 'required': ['x1', 'y1', 'x2', 'y2']}},
    {'name': 'type', 'description': 'Type text into the focused window.', 'inputSchema': {'type': 'object', 'properties': {'text': {'type': 'string'}}, 'required': ['text']}},
    {'name': 'key', 'description': 'Press a key or combination, e.g. "Return", "ctrl+s".', 'inputSchema': {'type': 'object', 'properties': {'combo': {'type': 'string'}}, 'required': ['combo']}},
    {'name': 'scroll', 'description': 'Scroll at (x, y): positive dy down, positive dx right, in wheel steps.',
     'inputSchema': {'type': 'object', 'properties': {'x': point, 'y': point, 'dx': point, 'dy': point}, 'required': ['x', 'y']}},
    {'name': 'launch', 'description': 'Start an application, e.g. "mousepad notes.txt" or "soffice --writer".',
     'inputSchema': {'type': 'object', 'properties': {'command': {'type': 'string'}}, 'required': ['command']}},
]


def step(name, a):
    if name == 'focus': return {'focus': a.get('window')}
    if name == 'click': return {'click': [a.get('x'), a.get('y')], **{k: a[k] for k in ('button', 'count') if k in a}}
    if name == 'drag': return {'drag': [a.get('x1'), a.get('y1'), a.get('x2'), a.get('y2')]}
    if name == 'type': return {'type': a.get('text')}
    if name == 'key': return {'key': a.get('combo')}
    if name == 'scroll': return {'scroll': [a.get('x'), a.get('y')], **{k: a[k] for k in ('dx', 'dy') if k in a}}
    if name == 'launch': return {'launch': a.get('command')}


child = subprocess.Popen(sys.argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)
pending = {}  # request id -> how to rewrite its reply
lock = threading.Lock()


def out(message):
    with lock:
        sys.stdout.write(json.dumps(message) + '\n'); sys.stdout.flush()


def downstream():
    for line in child.stdout:
        message = json.loads(line)
        kind = pending.pop(message.get('id'), None)
        result = message.get('result')
        if kind == 'list' and result is not None:
            result['tools'] = TOOLS
        elif kind == 'initialize' and result is not None:
            result.pop('instructions', None)
        elif kind in ('step', 'windows') and result is not None:
            text = ''.join(part.get('text', '') for part in result.get('content', []))
            if kind == 'windows':
                lines = text.split('\n')
                end = next((i for i, l in enumerate(lines) if l.startswith('In ') or l.startswith('No window has')), len(lines))
                text = '\n'.join(lines[:end])
            elif text.startswith('Did '):
                text = text.split('\n')[0]
            else:
                text = 'Done.'
            result['content'] = [{'type': 'text', 'text': text}]
        out(message)


threading.Thread(target=downstream, daemon=True).start()
for line in sys.stdin:
    if not line.strip(): continue
    message = json.loads(line)
    method, params = message.get('method'), message.get('params') or {}
    if method == 'initialize': pending[message.get('id')] = 'initialize'
    if method == 'tools/list': pending[message.get('id')] = 'list'
    if method == 'tools/call':
        name, args = params.get('name'), params.get('arguments') or {}
        if name == 'screenshot':
            params['arguments'] = {k: v for k, v in args.items() if k == 'window'}
        elif name == 'list_windows':
            params.update(name='look', arguments={'windows': True}); pending[message.get('id')] = 'windows'
        elif name in ('focus', 'click', 'drag', 'type', 'key', 'scroll', 'launch'):
            params.update(name='act', arguments={'steps': [step(name, args)], 'observe': False}); pending[message.get('id')] = 'step'
        else:
            out({'jsonrpc': '2.0', 'id': message.get('id'), 'error': {'code': -32602, 'message': f'unknown tool {name}'}}); continue
    child.stdin.write((json.dumps(message) + '\n').encode()); child.stdin.flush()
child.stdin.close(); child.wait()

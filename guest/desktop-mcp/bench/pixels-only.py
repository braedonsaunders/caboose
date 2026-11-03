#!/usr/bin/env python3
"""MCP stdio proxy for the screenshot baseline: runs the desktop MCP command given as
arguments and offers the agent only pictures, pointer and keyboard (no accessibility tree,
no annotated screenshots, no batch). Everything else passes through unchanged."""
import json
import subprocess
import sys
import threading

ALLOWED = {'screenshot', 'list_windows', 'focus', 'click', 'drag', 'type', 'key', 'scroll'}
child = subprocess.Popen(sys.argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE, bufsize=0)
lists = set()
lock = threading.Lock()


def out(message):
    with lock:
        sys.stdout.write(json.dumps(message) + '\n'); sys.stdout.flush()


def downstream():
    for line in child.stdout:
        message = json.loads(line)
        if message.get('id') in lists and 'result' in message:
            lists.discard(message['id'])
            tools = [t for t in message['result']['tools'] if t['name'] in ALLOWED]
            for tool in tools:
                tool['inputSchema'].get('properties', {}).pop('annotate', None)
                tool['inputSchema'].get('properties', {}).pop('observe', None)
            message['result']['tools'] = tools
        out(message)


threading.Thread(target=downstream, daemon=True).start()
for line in sys.stdin:
    if not line.strip(): continue
    message = json.loads(line)
    if message.get('method') == 'tools/list': lists.add(message.get('id'))
    if message.get('method') == 'tools/call':
        params = message.get('params') or {}
        if params.get('name') not in ALLOWED:
            out({'jsonrpc': '2.0', 'id': message.get('id'), 'error': {'code': -32602, 'message': f"unknown tool {params.get('name')}"}}); continue
        arguments = params.setdefault('arguments', {})
        arguments.pop('annotate', None)
        if params.get('name') in ('focus', 'click', 'drag', 'type', 'key', 'scroll'): arguments['observe'] = False
    child.stdin.write((json.dumps(message) + '\n').encode()); child.stdin.flush()
child.stdin.close(); child.wait()

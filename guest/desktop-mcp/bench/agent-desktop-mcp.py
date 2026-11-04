#!/usr/bin/env python3
"""MCP stdio server for comparing another accessibility layer: it offers the agent-desktop CLI
(github.com/vercel-labs/agent-desktop) as one tool, as its documentation says an agent uses it.

usage: agent-desktop-mcp.py PATH-TO-agent-desktop

Run inside the computer with the agent seat's environment and agent profile, like desktop
MCP. The tool `agent_desktop` takes `args` (the CLI's words after `agent-desktop`) and
returns the CLI's JSON envelope; a screenshot's base64 PNG is returned as an image. The
server's instructions are the line agent-desktop's README gives for an AGENTS.md."""
import json
import subprocess
import sys

BINARY = sys.argv[1]
INSTRUCTIONS = ('Use `agent-desktop` to see and operate desktop apps. Before the first use, run '
                '`agent-desktop skills get desktop` and `agent-desktop skills get platform`, and follow them.')
TOOL = {'name': 'agent_desktop', 'description': 'Run the agent-desktop CLI: args are the words after `agent-desktop`, '
        'e.g. ["snapshot", "--skeleton", "-i", "--compact"]. Returns its JSON envelope.',
        'inputSchema': {'type': 'object', 'properties': {'args': {'type': 'array', 'items': {'type': 'string'}}}, 'required': ['args']}}


def call(args):
    if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
        return [{'type': 'text', 'text': 'args must be a list of strings'}], True
    try:
        run = subprocess.run([BINARY, *args], capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        return [{'type': 'text', 'text': 'agent-desktop did not finish within 120 s'}], True
    out = run.stdout.strip() or run.stderr.strip()
    try:
        envelope = json.loads(out)
        data = envelope.get('data') if isinstance(envelope, dict) else None
        image = isinstance(data, dict) and (data.get('base64') or data.get('png_base64') or data.get('image'))
        if envelope.get('command') == 'screenshot' and isinstance(image, str):
            rest = {k: v for k, v in data.items() if not isinstance(v, str) or len(v) < 200}
            return [{'type': 'image', 'data': image, 'mimeType': 'image/png'}, {'type': 'text', 'text': json.dumps({**envelope, 'data': rest})}], False
    except ValueError:
        pass
    return [{'type': 'text', 'text': out[:200000]}], run.returncode != 0


def reply(message_id, result):
    sys.stdout.write(json.dumps({'jsonrpc': '2.0', 'id': message_id, 'result': result}) + '\n'); sys.stdout.flush()


for line in sys.stdin:
    if not line.strip():
        continue
    message = json.loads(line)
    method, message_id = message.get('method'), message.get('id')
    if method == 'initialize':
        reply(message_id, {'protocolVersion': (message.get('params') or {}).get('protocolVersion', '2025-06-18'), 'capabilities': {'tools': {}},
                           'serverInfo': {'name': 'agent-desktop', 'version': '1.1.0'}, 'instructions': INSTRUCTIONS})
    elif method == 'tools/list':
        reply(message_id, {'tools': [TOOL]})
    elif method == 'tools/call':
        params = message.get('params') or {}
        if params.get('name') != 'agent_desktop':
            sys.stdout.write(json.dumps({'jsonrpc': '2.0', 'id': message_id, 'error': {'code': -32602, 'message': 'unknown tool'}}) + '\n'); sys.stdout.flush()
            continue
        content, error = call((params.get('arguments') or {}).get('args'))
        reply(message_id, {'content': content, **({'isError': True} if error else {})})
    elif method == 'ping':
        reply(message_id, {})

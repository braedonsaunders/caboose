#!/usr/bin/env python3
"""Real-application benchmark: a big model drives the agent seat through desktop MCP.

usage: run.py --exec CMD --mcp CMD --mode native|pixels --model MODEL --output RESULTS.jsonl [--task ID ...]

--exec runs `bash -s` inside the computer as the agent user (it reads a script on stdin);
--mcp starts desktop MCP inside the computer on the agent seat (stdio). Both are shell
words, e.g. --exec 'ssh HOST docker exec -i -u caboose CONTAINER bash -s'. `native` offers
every desktop tool; `pixels` offers only screenshots, pointer and keyboard (pixels-only.py),
the screenshot computer-use baseline. Each task's setup starts its application, the Claude
Code CLI (`claude -p`, no built-in tools) runs the prompt, and the task's verify decides
success independently of what the model says. One JSON line per task: success, tool calls,
seconds, tokens and cost."""
import argparse
import fcntl
import json
import pathlib
import shlex
import subprocess
import sys
import tempfile
import time

here = pathlib.Path(__file__).resolve().parent
p = argparse.ArgumentParser()
p.add_argument('--exec', dest='exec_', required=True)
p.add_argument('--mcp', required=True)
p.add_argument('--mode', choices=['native', 'pixels'], required=True)
p.add_argument('--model', required=True)
p.add_argument('--agent', choices=['claude', 'codex'], default='claude', help='the CLI that runs the model: Claude Code or Codex')
p.add_argument('--label', help='what to call this run in its records (default: the mode), e.g. another layer served as --mcp')
p.add_argument('--output', required=True)
p.add_argument('--task', action='append', default=[])
p.add_argument('--timeout', type=int, default=900)
p.add_argument('--prompt-suffix', default='', help='appended to every task prompt ({id} is the task id), e.g. to have routines saved')
p.add_argument('--tools', default='/opt/caboose', help="directory of desktop MCP's helpers inside the computer")
p.add_argument('--trace', help='CABOOSE_DESKTOP_TRACE file of the --mcp server inside the computer, summarised per task')
a = p.parse_args()
tasks = [t for t in json.loads((here / 'tasks.json').read_text())['tasks'] if not a.task or t['id'] in a.task]
prelude = (here / 'prelude.sh').read_text()
BENCH = '/tmp/caboose-bench'


def computer(script, timeout=120):
    body = f"export BENCH={BENCH} TOOLS={shlex.quote(a.tools)}\nset -a; . /run/caboose/agent-display.env; set +a\n{prelude}\n{script}\n"
    r = subprocess.run(shlex.split(a.exec_), input=body, text=True, capture_output=True, timeout=timeout)
    return r.returncode, (r.stdout + r.stderr).strip()


PROMPT = ('You are operating a Linux desktop, the agent seat, through the caboose-desktop tools. '
          'The application for this task is already open and focused. Task: {task} '
          'Work until the task is done; do not ask questions. Finish with DONE, or FAILED and the reason.')
mcp = shlex.split(a.mcp)
server = ([sys.executable, str(here / 'pixels-only.py')] + mcp) if a.mode == 'pixels' else mcp
config = tempfile.NamedTemporaryFile('w', suffix='.json', delete=False)
json.dump({'mcpServers': {'desktop': {'command': server[0], 'args': server[1:]}}}, config); config.close()

# One run at a time on this machine: a second would share the agent seat.
lock = open(pathlib.Path(tempfile.gettempdir()) / 'caboose-bench.lock', 'w')
try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError: sys.exit('another benchmark run is in progress')
code, text = computer('windows')
if json.loads(text)['windows']:
    sys.exit('the agent seat has windows open; run on an empty seat')
for task in tasks:
    computer(f'end_apps; rm -rf "$BENCH"; mkdir -p "$BENCH"')
    code, text = computer(f"{task['setup']}\nwait_window {shlex.quote(task['app'])}", timeout=180)
    record = {'task': task['id'], 'mode': a.label or a.mode, 'model': a.model}
    if code != 0:
        record.update(success=False, error='setup: ' + text[-300:])
    else:
        time.sleep(1.0)  # the application finishes building its first window
        prompt = PROMPT.format(task=task['prompt']) + (' ' + a.prompt_suffix.format(id=task['id']) if a.prompt_suffix else '')
        if a.agent == 'claude':
            command = ['claude', '-p', prompt, '--model', a.model, '--output-format', 'stream-json', '--verbose',
                       '--tools', '', '--strict-mcp-config', '--mcp-config', config.name, '--allowedTools', 'mcp__desktop',
                       '--permission-mode', 'bypassPermissions', '--no-session-persistence', '--setting-sources', 'project']
        else:
            # Codex keeps its shell; the read-only sandbox has no network, so the computer is
            # reachable only through the desktop server.
            command = ['codex', 'exec', '--json', '--ephemeral', '--skip-git-repo-check', '--ignore-rules', '-s', 'read-only', '-m', a.model,
                       '-c', f'mcp_servers.desktop.command={json.dumps(server[0])}', '-c', f'mcp_servers.desktop.args={json.dumps(server[1:])}',
                       '-c', 'mcp_servers.desktop.tool_timeout_sec=180', '-c', 'mcp_servers.desktop.startup_timeout_sec=60', '-c', 'mcp_servers.desktop.default_tools_approval_mode="approve"', '-c', 'approval_policy="never"', prompt]
        started = time.monotonic()
        calls, names, result = 0, {}, {}
        try:
            run = subprocess.run(command, capture_output=True, text=True, timeout=a.timeout, cwd=tempfile.gettempdir())
            for line in run.stdout.splitlines():
                try: event = json.loads(line)
                except ValueError: continue
                if event.get('type') == 'assistant':
                    for part in event['message'].get('content', []):
                        if part.get('type') == 'tool_use':
                            calls += 1; name = part['name'].split('__')[-1]; names[name] = names.get(name, 0) + 1
                if event.get('type') == 'result': result = event
                # Codex: each MCP call is an item; each turn reports its usage.
                item = event.get('item') or {}
                if event.get('type') == 'item.completed' and item.get('type') == 'mcp_tool_call':
                    calls += 1; names[item.get('tool', '?')] = names.get(item.get('tool', '?'), 0) + 1
                if event.get('type') == 'item.completed' and item.get('type') == 'agent_message':
                    result['result'] = item.get('text', '')
                if event.get('type') == 'turn.completed':
                    u = event.get('usage') or {}
                    usage_ = result.setdefault('usage', {})
                    usage_['input_tokens'] = usage_.get('input_tokens', 0) + u.get('input_tokens', 0)
                    usage_['output_tokens'] = usage_.get('output_tokens', 0) + u.get('output_tokens', 0)
        except subprocess.TimeoutExpired:
            result = {'subtype': 'timeout'}
        seconds = time.monotonic() - started
        code, text = computer(task['verify'])
        if a.trace:
            _, lines = computer(f'cat {shlex.quote(a.trace)} 2>/dev/null; rm -f {shlex.quote(a.trace)}')
            calls_ = [json.loads(l) for l in lines.splitlines() if l.startswith('{')]
            record['server'] = {'ms': sum(c['ms'] for c in calls_), 'chars': sum(c['chars'] for c in calls_), 'images': sum(c['images'] for c in calls_),
                                'slowest': sorted(calls_, key=lambda c: -c['ms'])[:6]}
        usage = result.get('usage', {})
        record.update(success=code == 0, said=(result.get('result') or result.get('subtype') or '')[-200:], seconds=round(seconds, 1),
                      toolCalls=calls, tools=names, turns=result.get('num_turns'), costUsd=result.get('total_cost_usd'),
                      inputTokens=usage.get('input_tokens', 0) + usage.get('cache_creation_input_tokens', 0) + usage.get('cache_read_input_tokens', 0),
                      outputTokens=usage.get('output_tokens', 0))
    if task.get('reset'): computer(task['reset'])
    computer('end_apps')
    print(json.dumps(record), flush=True)
    with open(a.output, 'a') as f: f.write(json.dumps(record) + '\n')
computer('end_apps; rm -rf "$BENCH"')
pathlib.Path(config.name).unlink()

# Desktop benchmark

Real tasks in real applications on the agent seat, done by a big model through desktop
MCP. It compares the native tools (accessibility tree, semantic actions, batches) with a
screenshot computer-use baseline: the same model with only screenshots, pointer and
keyboard. Success is decided by each task's own check of the effect (a file, a setting, a
page title), never by what the model reports. The `direct-` tasks are ones a direct tool can
do without the GUI (a setting, a spreadsheet, a replace, files, a page's numbers); the
baseline does them through the GUI.

`tasks.json` lists the tasks. Each has a `setup` that creates its files and starts its
application, the `app` id of the window to wait for, the `prompt`, a `verify` command that
exits 0 only when the effect is there, and an optional `reset` for settings kept outside
the run directory. They run inside the computer as the agent user with the agent seat's
environment and `HOME=/tmp/caboose-bench/home`, after `prelude.sh`.

## Run

Needs the Claude Code CLI (`claude`, signed in) on the machine running the benchmark and a
command that reaches the computer. The agent seat must be empty: the run ends every
application on it between tasks.

```sh
python3 run.py --mode native --model claude-sonnet-5-5 --output native.jsonl \
  --exec 'ssh HOST docker exec -i -u caboose CONTAINER bash -s' \
  --mcp "ssh HOST \"docker exec -i -u caboose CONTAINER bash -c 'set -a; . /run/caboose/agent-display.env; set +a; CABOOSE_AGENT_PROFILE=/tmp/caboose-bench exec node /opt/caboose/desktop-mcp.mjs'\""
```

`CABOOSE_AGENT_PROFILE=/tmp/caboose-bench` makes the run directory the server's agent profile,
so an application the agent launches has the same home as the task's files.

`--trace FILE` names the `CABOOSE_DESKTOP_TRACE` file the `--mcp` server writes inside the
computer; each task's record then has `server` (tool milliseconds, reply characters,
images, slowest calls). `--mode pixels` runs the baseline through `pixels-only.py`, which offers only
`screenshot` (without annotation), `list_windows`, `focus`, `click`, `drag`, `type`, `key`
and `scroll`. `--task ID` (repeatable) runs a subset. Each task writes one JSON line:
`success`, `toolCalls` (and per tool), `seconds` (the model's whole run), `turns`,
`inputTokens` (including cached), `outputTokens` and `costUsd`. The model runs with no
built-in tools, so it can reach the computer only through the desktop tools.

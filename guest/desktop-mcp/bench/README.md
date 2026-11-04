# Desktop benchmark

Real tasks in real applications on the agent seat, done by a big model through desktop
MCP. It compares the native tools (accessibility tree, semantic actions, batches) with a
screenshot computer-use baseline: the same model with only screenshots, pointer and
keyboard. Success is decided by each task's own check of the effect (a file, a setting, a
page title), never by what the model reports. The `flathub-` tasks run Flathub applications (GNOME Text Editor and Calculator, Gnumeric,
Kate, Okular, GIMP, VSCodium) and the `wine-` tasks Windows programs (Notepad++, Notepad,
7-Zip) from the agent profile's installations. The `direct-` tasks are ones a direct tool can
do without the GUI (a setting, a spreadsheet, a replace, files, a page's numbers); the
baseline does them through the GUI.

`tasks.json` lists the tasks. Each has a `setup` that creates its files and starts its
application, the `app` id of the window to wait for, the `prompt`, a `verify` command that
exits 0 only when the effect is there, and an optional `reset` for settings kept outside
the run directory. They run inside the computer as the agent user with the agent seat's
environment and `HOME=/home/caboose/caboose-bench/home`, after `prelude.sh`.

## Run

Needs the Claude Code CLI (`claude`, signed in) on the machine running the benchmark, or with
`--agent codex` the Codex CLI (`codex`, signed in), and a command that reaches the computer. The agent seat must be empty: the run ends every
application on it between tasks.

```sh
python3 run.py --mode native --model claude-sonnet-5-5 --output native.jsonl \
  --exec 'ssh HOST docker exec -i -u caboose CONTAINER bash -s' \
  --mcp "ssh HOST \"docker exec -i -u caboose CONTAINER bash -c 'set -a; . /run/caboose/agent-display.env; set +a; CABOOSE_AGENT_PROFILE=/home/caboose/caboose-bench exec node /opt/caboose/desktop-mcp.mjs'\""
```

`CABOOSE_AGENT_PROFILE=/home/caboose/caboose-bench` makes the run directory the server's agent profile
(under the home: a Flatpak sandbox has its own `/tmp`, so a home there would be out of its sight),
so an application the agent launches has the same home as the task's files.

A run stops, recording nothing for the task, when the agent itself reports an error before any
tool call (no usable account, a provider outage, a desktop server Codex could not start). `repeat.sh OUT-DIR [N] [MODEL]` (with `EXEC` and `MCP` set as above, `MCP` with
`CABOOSE_DESKTOP_TRACE=/tmp/caboose-bench-trace.jsonl`) runs every task N times, native then
pixels each round, and writes `summary.md` with `summarize.py`, which totals any record files
per set (single-application, `flow-`, `direct-`) and mode, then each task. `results/` keeps
the summaries of the runs reported.

`--trace FILE` names the `CABOOSE_DESKTOP_TRACE` file the `--mcp` server writes inside the
computer; each task's record then has `server` (tool milliseconds, reply characters,
images, slowest calls). `--mode pixels` runs the baseline through `pixels-only.py`, which offers only
`screenshot` (without annotation), `list_windows`, `focus`, `click`, `drag`, `type`, `key`
and `scroll`. `--task ID` (repeatable) runs a subset. Each task writes one JSON line:
`success`, `toolCalls` (and per tool), `seconds` (the model's whole run), `turns`,
`inputTokens` (including cached), `outputTokens` and `costUsd`. The model runs with no
built-in tools, so it can reach the computer only through the desktop tools.

# Accessibility coverage survey

`survey.py` starts every application on the agent seat, one at a time as desktop MCP's
`launch` starts it, and scores how well its window can be read and driven without pixels:
whether the accessibility tree is found, how many controls a read lists and how many have a
name, whether the window's text reads, how many interactive controls offer an action,
whether focusing a control by id takes, and how long a read takes. Applications are grouped
by toolkit and runtime (GTK 3/4, Qt 5/6, Chromium/Electron, Gecko, LibreOffice VCL, Java,
Wine, SDL, and Flatpak), from the libraries the window's process maps.

It reads the desktop entries of the image and of the system and user Flatpak installations;
`--only ID` and `--skip ID` (repeatable) narrow the list. Run it inside the computer as the
agent user, on an empty agent seat, in the agent profile, from this directory's parent:

```sh
set -a; . /run/caboose/agent-display.env; set +a
python3 /opt/caboose/agent-profile.py exec python3 coverage/survey.py --output coverage.jsonl
python3 coverage/survey.py --table coverage.jsonl
```

Applications run with the agent profile's home, as an agent's would. The survey ends each
one before starting the next; it never touches the owner's seat.

`results/` keeps the reported surveys and what was fixed after each.

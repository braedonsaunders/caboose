# Sonnet 5.5, 47 tasks, n=3, with direct tools (host 9474c206)

The 30 single-application tasks, the 11 `flow-` workflows and the 6 `direct-` tasks, three
rounds, native then pixels each round (`repeat.sh`; `summarize.py` over the records).

| Set | Mode | Success | Mean / median s | Calls | Input tokens | $/task |
|---|---|---|---|---|---|---|
| 30 single-app | native | 90/90 | 9.9 / 6.6 | 5.0 | 25k | 0.014 |
| 30 single-app | pixels | 90/90 | 12.6 / 8.8 | 12.0 | 58k | 0.028 |
| 11 workflows | native | 30/33 | 11.5 / 9.0 | 6.3 | 33k | 0.021 |
| 11 workflows | pixels | 32/33 | 23.8 / 16.0 | 23.7 | 129k | 0.058 |
| 6 direct | native | 18/18 | 7.1 / 6.3 | 3.3 | 19k | 0.012 |
| 6 direct | pixels | 18/18 | 13.5 / 12.3 | 16.0 | 48k | 0.031 |

| Task | native: ok, s, calls | pixels: ok, s, calls |
|---|---|---|
| mousepad-save-as | 3/3, 6, 4 | 3/3, 9, 10 |
| mousepad-find-replace | 3/3, 6, 4 | 3/3, 12, 19 |
| mousepad-preference | 3/3, 8, 5 | 3/3, 14, 10 |
| thunar-create-folder | 3/3, 7, 3 | 3/3, 9, 7 |
| thunar-rename | 3/3, 6, 3 | 3/3, 8, 9 |
| thunar-preference | 3/3, 6, 2 | 3/3, 8, 8 |
| chromium-form | 3/3, 5, 2 | 3/3, 7, 9 |
| chromium-two-page | 3/3, 6, 3 | 3/3, 9, 11 |
| writer-save | 3/3, 8, 4 | 3/3, 11, 8 |
| calc-sum | 3/3, 9, 5 | 3/3, 12, 8 |
| terminal-command | 3/3, 7, 3 | 3/3, 4, 2 |
| vscode-edit | 3/3, 21, 10 | 3/3, 6, 5 |
| keepassxc-new-database | 3/3, 25, 16 | 3/3, 39, 48 |
| zenity-form | 3/3, 5, 2 | 3/3, 11, 7 |
| keyboard-settings | 3/3, 6, 3 | 3/3, 7, 5 |
| impress-title | 3/3, 12, 6 | 3/3, 25, 21 |
| thunar-copy | 3/3, 14, 8 | 3/3, 8, 7 |
| thunar-trash | 3/3, 6, 3 | 3/3, 8, 6 |
| chromium-select | 3/3, 7, 3 | 3/3, 11, 10 |
| writer-docx | 3/3, 15, 10 | 3/3, 35, 28 |
| calc-csv-total | 3/3, 6, 2 | 3/3, 12, 12 |
| terminal-mkdir | 3/3, 5, 2 | 3/3, 4, 3 |
| keepassxc-add-entry | 3/3, 10, 5 | 3/3, 16, 21 |
| zenity-list | 3/3, 8, 3 | 3/3, 7, 5 |
| zenity-calendar | 3/3, 10, 4 | 3/3, 6, 5 |
| vscode-new-file | 3/3, 27, 11 | 3/3, 16, 17 |
| file-roller-extract | 3/3, 31, 16 | 3/3, 36, 31 |
| webmcp-shop | 3/3, 5, 2 | 3/3, 11, 12 |
| webmcp-berth | 3/3, 7, 3 | 3/3, 6, 7 |
| webmcp-derived-form | 3/3, 4, 2 | 3/3, 7, 9 |
| flow-download-extract-edit | 3/3, 32, 15 | 2/3, 76, 75 |
| flow-text-to-pdf | 3/3, 13, 5 | 3/3, 24, 26 |
| flow-folder-move-edit | 3/3, 7, 4 | 3/3, 32, 35 |
| flow-calc-to-web | 3/3, 9, 4 | 3/3, 23, 18 |
| flow-terminal-to-editor | 3/3, 8, 5 | 3/3, 11, 9 |
| flow-writer-letter | 3/3, 14, 10 | 3/3, 16, 14 |
| flow-web-wizard | 3/3, 7, 5 | 3/3, 15, 20 |
| flow-two-preferences | 0/3, 6, 4 | 3/3, 16, 13 |
| flow-dialog-to-file | 3/3, 6, 4 | 3/3, 11, 13 |
| flow-vscode-project | 3/3, 12, 7 | 3/3, 24, 25 |
| flow-keepass-to-web | 3/3, 13, 7 | 3/3, 14, 12 |
| direct-mousepad-wrap | 3/3, 10, 7 | 3/3, 13, 11 |
| direct-thunar-hidden | 3/3, 8, 4 | 3/3, 10, 8 |
| direct-calc-table | 3/3, 6, 2 | 3/3, 9, 9 |
| direct-writer-replace | 3/3, 7, 2 | 3/3, 16, 23 |
| direct-files-sort | 3/3, 5, 2 | 3/3, 22, 40 |
| direct-browser-total | 3/3, 7, 3 | 3/3, 12, 6 |

The three native failures were all `flow-two-preferences`: a GApplication toggle set by
SetState changed Mousepad's action but not its setting. After toggles went through the
application's own handler (host eaa160ac), it passed 3 of 3, with `mousepad-preference` and
`direct-mousepad-wrap` 3 of 3 each.

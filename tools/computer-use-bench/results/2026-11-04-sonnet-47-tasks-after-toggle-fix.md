# Sonnet 5.5, 47 tasks, n=3, after the toggle fix (host d900e2ed)

The 30 single-application tasks, the 11 `flow-` workflows and the 6 `direct-` tasks, three
rounds, native then pixels each round (`repeat.sh`; the third round resumed after the
connection to the computer stalled; `summarize.py` over the records).

| Set | Mode | Success | Mean / median s | Calls | Input tokens | $/task |
|---|---|---|---|---|---|---|
| 30 single-app | native | 90/90 | 9.9 / 7.2 | 5.4 | 27k | 0.016 |
| 30 single-app | pixels | 90/90 | 14.1 / 9.8 | 11.9 | 53k | 0.029 |
| 11 workflows | native | 31/33 | 15.6 / 9.5 | 6.3 | 34k | 0.021 |
| 11 workflows | pixels | 32/33 | 22.7 / 20.5 | 21.6 | 104k | 0.053 |
| 6 direct | native | 18/18 | 7.1 / 6.3 | 3.6 | 20k | 0.013 |
| 6 direct | pixels | 18/18 | 13.2 / 11.1 | 12.4 | 39k | 0.027 |

| Task | native: ok, s, calls | pixels: ok, s, calls |
|---|---|---|
| mousepad-save-as | 3/3, 6, 4 | 3/3, 12, 10 |
| mousepad-find-replace | 3/3, 7, 5 | 3/3, 20, 22 |
| mousepad-preference | 3/3, 6, 5 | 3/3, 13, 11 |
| thunar-create-folder | 3/3, 10, 6 | 3/3, 9, 7 |
| thunar-rename | 3/3, 5, 3 | 3/3, 8, 8 |
| thunar-preference | 3/3, 5, 2 | 3/3, 9, 5 |
| chromium-form | 3/3, 4, 2 | 3/3, 7, 9 |
| chromium-two-page | 3/3, 5, 3 | 3/3, 10, 11 |
| writer-save | 3/3, 9, 4 | 3/3, 10, 11 |
| calc-sum | 3/3, 8, 4 | 3/3, 17, 11 |
| terminal-command | 3/3, 5, 3 | 3/3, 6, 3 |
| vscode-edit | 3/3, 18, 8 | 3/3, 10, 5 |
| keepassxc-new-database | 3/3, 20, 15 | 3/3, 40, 34 |
| zenity-form | 3/3, 6, 2 | 3/3, 9, 8 |
| keyboard-settings | 3/3, 6, 3 | 3/3, 10, 5 |
| impress-title | 3/3, 15, 6 | 3/3, 47, 39 |
| thunar-copy | 3/3, 15, 9 | 3/3, 8, 8 |
| thunar-trash | 3/3, 6, 3 | 3/3, 8, 6 |
| chromium-select | 3/3, 8, 3 | 3/3, 14, 11 |
| writer-docx | 3/3, 14, 11 | 3/3, 27, 22 |
| calc-csv-total | 3/3, 8, 2 | 3/3, 9, 7 |
| terminal-mkdir | 3/3, 4, 2 | 3/3, 6, 3 |
| keepassxc-add-entry | 3/3, 10, 6 | 3/3, 16, 19 |
| zenity-list | 3/3, 10, 4 | 3/3, 7, 5 |
| zenity-calendar | 3/3, 11, 5 | 3/3, 6, 5 |
| vscode-new-file | 3/3, 23, 15 | 3/3, 26, 23 |
| file-roller-extract | 3/3, 35, 19 | 3/3, 29, 23 |
| webmcp-shop | 3/3, 5, 2 | 3/3, 16, 12 |
| webmcp-berth | 3/3, 7, 3 | 3/3, 8, 7 |
| webmcp-derived-form | 3/3, 5, 2 | 3/3, 7, 9 |
| flow-download-extract-edit | 3/3, 70, 22 | 3/3, 38, 37 |
| flow-text-to-pdf | 3/3, 11, 5 | 3/3, 29, 29 |
| flow-folder-move-edit | 3/3, 7, 3 | 3/3, 23, 30 |
| flow-calc-to-web | 3/3, 11, 4 | 3/3, 31, 25 |
| flow-terminal-to-editor | 3/3, 9, 5 | 3/3, 10, 8 |
| flow-writer-letter | 3/3, 9, 5 | 3/3, 16, 15 |
| flow-web-wizard | 3/3, 10, 5 | 3/3, 19, 21 |
| flow-two-preferences | 3/3, 8, 5 | 2/3, 20, 9 |
| flow-dialog-to-file | 3/3, 7, 5 | 3/3, 14, 14 |
| flow-vscode-project | 1/3, 15, 4 | 3/3, 35, 38 |
| flow-keepass-to-web | 3/3, 15, 7 | 3/3, 16, 12 |
| direct-mousepad-wrap | 3/3, 10, 8 | 3/3, 14, 9 |
| direct-thunar-hidden | 3/3, 7, 4 | 3/3, 9, 6 |
| direct-calc-table | 3/3, 7, 3 | 3/3, 11, 8 |
| direct-writer-replace | 3/3, 6, 2 | 3/3, 20, 20 |
| direct-files-sort | 3/3, 5, 2 | 3/3, 18, 25 |
| direct-browser-total | 3/3, 8, 3 | 3/3, 9, 6 |

The two native failures were `flow-vscode-project`: the agent wrote the files with
`files.write` to `~/harbor` instead of the window's `~/Documents/harbor`. `flow-two-preferences`,
which failed 3 of 3 before the toggle fix, passed 3 of 3.

# Sonnet 5.5, 60 tasks, n=3 (host a90d8c0c)

The 30 single-application tasks, 10 `flathub-` and 3 `wine-` tasks, the 11 `flow-` workflows and
the 6 `direct-` tasks, three rounds, native then pixels each round (`repeat.sh`).

This ran before container computers had FUSE: a sandboxed Flatpak app could not save through
its file dialog at all (no document portal), which most of the pixel baseline's Flathub
failures are; native agents wrote the files with `files.write` instead.

| Set | Mode | Success | Mean / median s | Calls | Input tokens | $/task |
|---|---|---|---|---|---|---|
| 30 single-app | native | 90/90 | 8.7 / 6.7 | 4.6 | 24k | 0.015 |
| 30 single-app | pixels | 90/90 | 12.8 / 9.4 | 10.4 | 41k | 0.026 |
| 10 Flathub | native | 26/30 | 45.9 / 27.4 | 22.8 | 222k | 0.090 |
| 10 Flathub | pixels | 7/30 | 56.6 / 25.5 | 33.8 | 368k | 0.122 |
| 3 Wine | native | 8/9 | 17.5 / 15.3 | 7.9 | 36k | 0.021 |
| 3 Wine | pixels | 6/9 | 19.4 / 18.5 | 16.7 | 71k | 0.043 |
| 11 workflows | native | 33/33 | 10.8 / 9.7 | 5.8 | 31k | 0.021 |
| 11 workflows | pixels | 33/33 | 22.4 / 19.8 | 21.9 | 110k | 0.057 |
| 6 direct | native | 18/18 | 7.3 / 6.1 | 2.9 | 17k | 0.013 |
| 6 direct | pixels | 18/18 | 14.8 / 14.1 | 14.2 | 48k | 0.033 |

| Task | native: ok, s, calls | pixels: ok, s, calls |
|---|---|---|
| mousepad-save-as | 3/3, 7, 4 | 3/3, 12, 12 |
| mousepad-find-replace | 3/3, 8, 5 | 3/3, 13, 18 |
| mousepad-preference | 3/3, 8, 5 | 3/3, 12, 10 |
| thunar-create-folder | 3/3, 5, 2 | 3/3, 10, 7 |
| thunar-rename | 3/3, 6, 3 | 3/3, 8, 7 |
| thunar-preference | 3/3, 5, 2 | 3/3, 8, 6 |
| chromium-form | 3/3, 4, 2 | 3/3, 8, 9 |
| chromium-two-page | 3/3, 6, 4 | 3/3, 28, 11 |
| writer-save | 3/3, 9, 5 | 3/3, 11, 8 |
| calc-sum | 3/3, 8, 4 | 3/3, 9, 8 |
| terminal-command | 3/3, 4, 2 | 3/3, 4, 2 |
| vscode-edit | 3/3, 14, 8 | 3/3, 7, 5 |
| keepassxc-new-database | 3/3, 23, 15 | 3/3, 54, 37 |
| zenity-form | 3/3, 4, 2 | 3/3, 8, 7 |
| keyboard-settings | 3/3, 7, 3 | 3/3, 10, 6 |
| impress-title | 3/3, 10, 6 | 3/3, 21, 16 |
| thunar-copy | 3/3, 11, 6 | 3/3, 7, 7 |
| thunar-trash | 3/3, 6, 3 | 3/3, 9, 6 |
| chromium-select | 3/3, 5, 2 | 3/3, 12, 10 |
| writer-docx | 3/3, 13, 10 | 3/3, 16, 12 |
| calc-csv-total | 3/3, 7, 2 | 3/3, 14, 12 |
| terminal-mkdir | 3/3, 4, 2 | 3/3, 5, 3 |
| keepassxc-add-entry | 3/3, 10, 6 | 3/3, 12, 14 |
| zenity-list | 3/3, 7, 3 | 3/3, 8, 4 |
| zenity-calendar | 3/3, 11, 4 | 3/3, 6, 5 |
| vscode-new-file | 3/3, 7, 3 | 3/3, 23, 22 |
| file-roller-extract | 3/3, 35, 17 | 3/3, 27, 21 |
| webmcp-shop | 3/3, 5, 2 | 3/3, 10, 11 |
| webmcp-berth | 3/3, 7, 3 | 3/3, 7, 7 |
| webmcp-derived-form | 3/3, 5, 2 | 3/3, 8, 9 |
| flow-download-extract-edit | 3/3, 21, 12 | 3/3, 48, 41 |
| flow-text-to-pdf | 3/3, 12, 6 | 3/3, 23, 26 |
| flow-folder-move-edit | 3/3, 7, 4 | 3/3, 33, 35 |
| flow-calc-to-web | 3/3, 11, 5 | 3/3, 19, 17 |
| flow-terminal-to-editor | 3/3, 10, 4 | 3/3, 9, 8 |
| flow-writer-letter | 3/3, 13, 9 | 3/3, 24, 28 |
| flow-web-wizard | 3/3, 7, 5 | 3/3, 20, 20 |
| flow-two-preferences | 3/3, 8, 5 | 3/3, 18, 15 |
| flow-dialog-to-file | 3/3, 7, 5 | 3/3, 13, 14 |
| flow-vscode-project | 3/3, 10, 4 | 3/3, 24, 25 |
| flow-keepass-to-web | 3/3, 12, 7 | 3/3, 15, 13 |
| direct-mousepad-wrap | 3/3, 7, 3 | 3/3, 14, 9 |
| direct-thunar-hidden | 3/3, 11, 5 | 3/3, 14, 10 |
| direct-calc-table | 3/3, 8, 2 | 3/3, 10, 8 |
| direct-writer-replace | 3/3, 6, 2 | 3/3, 21, 26 |
| direct-files-sort | 3/3, 6, 2 | 3/3, 19, 27 |
| direct-browser-total | 3/3, 6, 3 | 3/3, 12, 6 |
| flathub-texteditor-save | 2/3, 87, 48 | 0/3, 237, 98 |
| flathub-texteditor-edit | 3/3, 32, 13 | 0/3, 8, 5 |
| flathub-calculator-product | 3/3, 10, 5 | 3/3, 7, 5 |
| flathub-gnumeric-total | 2/3, 134, 68 | 0/3, 121, 68 |
| flathub-kate-replace | 3/3, 32, 19 | 0/3, 16, 11 |
| flathub-kate-new | 1/3, 97, 51 | 0/3, 29, 28 |
| flathub-okular-read | 3/3, 11, 4 | 0/3, 25, 19 |
| flathub-gimp-export | 3/3, 29, 9 | 3/3, 28, 20 |
| flathub-codium-file | 3/3, 9, 3 | 0/3, 50, 39 |
| wine-notepadpp-append | 3/3, 8, 3 | 3/3, 9, 8 |
| wine-notepad-save | 2/3, 26, 9 | 0/3, 21, 16 |
| wine-7zip-extract | 3/3, 19, 12 | 3/3, 29, 26 |
| flathub-texteditor-to-files | 3/3, 17, 7 | 1/3, 46, 45 |

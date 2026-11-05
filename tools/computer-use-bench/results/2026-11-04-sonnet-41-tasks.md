# Sonnet 5.5, 41 tasks, n=3 (host 405f56f7)

The 30 single-application tasks and the 11 `flow-` workflows, three rounds, native then
pixels each round. The per-run records of this run were lost; these are its totals as
`summarize.py` printed them.

| Set | Mode | Success | Mean / median s | Calls | Input tokens | $/task |
|---|---|---|---|---|---|---|
| 30 single-app | native | 88/90 | 9.2 / 7.1 | 5.6 | 28k | 0.016 |
| 30 single-app | pixels | 90/90 | 12.2 / 9.9 | 11.4 | 52k | 0.028 |
| 11 workflows | native | 31/33 | 19.6 / 14.1 | 13.6 | 83k | 0.043 |
| 11 workflows | pixels | 33/33 | 18.8 / 18.9 | 21.1 | 97k | 0.051 |

The four native failures were `file-roller-extract` (2: the first Extract dialog took seconds
to map) and `flow-writer-letter` (2: LibreOffice applied ctrl+b after the text typed next);
both were fixed afterwards and passed 3 of 3 in a re-run.

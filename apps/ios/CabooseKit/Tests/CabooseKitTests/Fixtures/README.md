# Test fixtures

Files the CabooseKit tests read from disk. The test target excludes this directory from its
sources (`Package.swift`), and the tests open the files by path.

- `live-zstd-stream-vectors.json`: the algorithm 2 (zstd-stream) vectors of
  `guest/gpu/broker/live-zstd-stream-vectors.json`, kept identical to that file, for
  `LiveGPUZstdTests.swift`: `sequence` decodes in order on one stream, each `invalid` record
  fails as the first record of a new one.
- `live-zstd-binding-vectors.json`: four DATA envelopes for process 1 stream 1 (sequences 5
  to 8, executor of sixteen 1 bytes, generation 7) with their algorithm 2 records, for the
  binding test in `LiveGPUNativeBindingTests.swift`. Made with
  `python3 live-zstd-binding-vectors.py > live-zstd-binding-vectors.json` (needs libzstd).

# Test fixtures

Files the CabooseKit tests read from disk. The test target excludes this directory from its
sources (`Package.swift`), and the tests open the files by path.

- `av1-64x64.obu`: three AV1 temporal units (low-overhead OBUs, low-delay, no hidden
  frames) of ffmpeg's `testsrc2` at 64x64, for the hardware AV1 decode test in
  `DisplayDecodeTests.swift`, which runs where the Mac has an AV1 decoder. Made with:

  ```sh
  ffmpeg -f lavfi -i testsrc2=size=64x64:rate=30 -frames:v 3 -c:v libsvtav1 -preset 10 \
    -svtav1-params "keyint=30:pred-struct=1" -pix_fmt yuv420p -f obu av1-64x64.obu
  ```

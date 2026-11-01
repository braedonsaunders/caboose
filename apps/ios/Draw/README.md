# CabooseDraw (`apps/ios/Draw`)

Draws Caboose draw lists ([docs/draw.md](../../../docs/draw.md)) with Skia's Ganesh backend
on Metal: applications' cairo drawing, recorded on the computer (`guest/draw`), drawn again
by the phone's GPU. It is the phone's counterpart of `guest/draw/src/cdl_replay.c`, which
draws the same lists with cairo and is the reference it is checked against.

| Path | What |
| --- | --- |
| `include/CabooseDraw.h` | The C API: a renderer per connection, `feed` a stream's `draw.ops`, `texture` a surface for `draw.present`, `end` a stream |
| `src/renderer.mm` | The renderer: one Skia call per op, every surface an `MTLTexture` of its own |

Each surface is a Metal texture the renderer allocates and Skia draws into, so a texture the
app is showing is never reused for something else. Drawing goes on the app's shared surface
queue (`SurfaceRenderer`), so a copy the app encodes on that queue after `caboose_draw_texture`
sees the surface drawn. Operators are cairo's, mapped to Skia blend modes (`SATURATE` draws as
`PLUS`); cairo's unbounded operators (`SOURCE`, `IN`, `OUT`, `DEST_IN`, `DEST_ATOP`) affect
only the drawn shape, as in Skia.

## Build

    sh apps/ios/scripts/build-draw.sh apps/ios/CabooseKit/Frameworks

builds Skia at the commit the script pins (milestone 157) from source, with Ganesh on Metal and
nothing that needs a third-party library, compiles the renderer, and packages
`CabooseDraw.xcframework` for iOS, the iOS simulator and macOS. The checkout and builds stay in
`CABOOSE_SKIA_ROOT` (default `~/Library/Caches/caboose-skia`); `CABOOSE_SKIA_JOBS` (default 3)
caps the parallelism. The framework is a build product and not checked in. CabooseKit links it
when it is in `CabooseKit/Frameworks`. SwiftPM caches the manifest's answer to that, so after
adding or removing the framework, remove `~/Library/Caches/org.swift.swiftpm/manifests` and
the package's `.build`.

## Use

With the framework linked, the display session always asks for draw lists (`draw` in the
hello). The computer sends each window picture as a `draw.present` where an application's
recorder covers it completely, and as a Surface Atlas batch everywhere else; the session shows
either as the window's picture and acknowledges both. A picture it cannot draw is acknowledged
as failed with a keyframe request, which brings a batch.

## Test

    cd apps/ios/CabooseKit && swift test --filter DrawRendererTests

feeds a GTK 3 window recorded by `guest/draw` (`Tests/CabooseKitTests/Fixtures/draw/gtk3.cdl`)
to the renderer and compares the frame with what cairo drew of it (`surface-48-0000.png`, from
`caboose-draw-replay`): above 27 dB, and under 6% of pixels differing by more than 8 levels
(two rasterizers anti-alias edges differently). It also draws the frame at 3× and checks it is
complete. `CABOOSE_DRAW_TEST_PNG=PATH` writes that 3× picture.

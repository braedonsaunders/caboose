# Video composition and pause acceptance

`overlay.html` is an offline application fixture, not product UI. It accepts local
clips and contains native controls, an exact gray control, a translucent control,
subtitles, a popup and two independently controlled, cropped/scaled videos.
`requestVideoFrameCallback` reports application presentation; that report alone does
not prove what a phone displays.

The automated local checks are `build/av1-state`, codec roundtrips, and the display
`passthrough` admission check. These establish source state, software-decoded pixels
and local-decode admission respectively. They do not establish native hardware decode.

On an explicitly authorized isolated guest and phone, load this fixture with a fresh
browser profile and a synthetic clip with a burned-in frame number. Run each of H.264,
HEVC and AV1 separately; codec support in the browser must be recorded, and unsupported
codecs are skips, not passes. Record host/client versions, hardware decoder selection,
clip hash, and screenshots from guest and phone at the same paused frame.

1. Show/hide native controls and subtitles; open the menu; inspect gray controls,
   translucent edges and the opaque occluder against the guest reference.
2. Play both videos, resize the window to force scaling/cropping, pause each separately,
   then pause both. Compare the visible burned-in last-frame number to the guest,
   including pauses on a non-key AV1 frame. Resume and repeat across a keyframe boundary.
3. Cover/uncover the video, switch tabs, reconnect, and reuse decoder surfaces. No stale
   tag or sequence may replace a newer or different picture; an ambiguous marker is
   never evidence for alpha. Current admission requests server decode throughout.
4. Check nearby static text after settling and after scrolling. Compare lossless text
   tiles and unchanged audio clock behavior with baseline; record any regression.

A native passthrough acceptance run requires independent, lossless foreground/alpha
provenance and an atomic binding to the full frame sequence, composition generation,
transform, crop and ordering. Current marker messages provide none of these. Gray
matching, a surviving marker tag, and success decoding an access unit do not satisfy
this gate. No decoder advertisement or Metal punchthrough is enabled by these fixtures.

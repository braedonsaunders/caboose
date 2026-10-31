# Caboose Linux Guest Scene Graph Interceptor & WSI Promotion (`guest/scene`)

This directory implements the Linux guest userspace components for **Lane 2 (Semantic Scene Graph & Vector Glyph Stream)**, the **Chromium / Electron Layer Bridge**, and **Implicit Vulkan WSI / Mesa Zink Promotion** in the Caboose OS Decomposition ("Zero Server Video") architecture.

## Components

1. **`src/scene_wire.h`**
   - Self-contained C11 header providing:
     - 64-bit `cb_xxh64(data, len, seed)` matching `caboose-display-protocol::xxh64` (`cb_xxh64("", 0, 0) == 0xEF46DB3751D8E999`).
     - RFC 8949 canonical CBOR encoders (definite-length arrays/maps, minimal integer width, canonical key sorting: shorter byte length first, then lexicographical).
     - Builders for 5-byte framed (`type: u8, length: u32 LE`) `0x25` (`scene.font`) and `0x26` (`scene.commit`) messages (`rect`, `rclip`, `scroll`, `glyphs` with tight 10-byte `(uint16_t glyph_id, float x, float y)` little-endian records, and `path` binary verb+point streams).
     - Non-blocking `AF_UNIX` client (`cb_scene_client_t`) connecting to `$CABOOSE_SCENE_SOCKET` and polling `0x9A` (`scene.scroll`) events from `caboose-display`.
     - **Invariant A (Headless Liveness)**: If `$CABOOSE_SCENE_SOCKET` is unset, missing, refuses connection, or returns `EAGAIN`/`EPIPE` on write, `cb_scene_client_t` immediately drops into non-blocking local passthrough mode without stalling or raising `SIGPIPE`.

2. **`src/caboose_scene_cairo.c` (`libcaboose_scene_cairo.so`)**
   - `LD_PRELOAD`-compatible Cairo/GTK/Qt interceptor using `dlsym(RTLD_NEXT, ...)` with zero link-time dependency on `libcairo`.
   - Exposes the explicit C API (`caboose_scene_register_font`, `caboose_scene_begin_frame`, `caboose_scene_push_rect`, `caboose_scene_push_rclip`, `caboose_scene_push_scroll`, `caboose_scene_push_glyphs`, `caboose_scene_push_path`, `caboose_scene_commit_frame`, `caboose_scene_poll_scroll`).
   - Deduplicates `(font_hash, face_index)` per session so `0x25` (`scene.font`) is sent only once per font face.

3. **`chromium/caboose-chromium-scene.conf`**
   - Environment and command-line flags configuration for Chromium and Electron apps (`claude-desktop`, `chatgpt`, `code`, `obsidian`, `chromium`) enabling Ozone-Wayland subsurface delegation (`WaylandOverlayDelegation`), hardware VA-API decode (`VaapiVideoDecodeLinuxGL,VaapiVideoDecoder`), and smooth scroll tree emission.

4. **`wsi/caboose_wsi_promote.json` & `wsi/caboose_wsi_promote.c` (`libcaboose_wsi_promote.so`)**
   - Implicit Vulkan layer (`VK_LAYER_CABOOSE_wsi_promote`) and Mesa Zink OpenGL-to-Vulkan promotion gate (`caboose_wsi_should_promote_process()`).
   - Strictly gated on `CABOOSE_WSI_AUTO_PROMOTE=1` (set only on the owner seat, never on the agent seat). Promotes 3D / Vulkan / Zink / Proton workloads when `vkCreateSwapchainKHR` is called while keeping 2D desktop UI/launchers on the Scene Graph / Surface Atlas lanes.

## Building & Testing

```sh
sh guest/scene/check.sh
```

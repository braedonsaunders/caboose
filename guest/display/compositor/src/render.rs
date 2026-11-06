//! Renders each window's surface tree on the GPU, into images the phone shows.
//!
//! The compositor is an OpenGL ES client of Mesa's Zink on the computer's Vulkan devices:
//! the phone's GPU through the Caboose driver while a phone executor is attached, otherwise
//! the computer's CPU implementation, which the routing layer presents as a GPU
//! (guest/gpu/routing-layer). EGL runs on Mesa's software device, whose Gallium driver is
//! Zink.
//!
//! With the phone's GPU, every window is rendered into its own phone-resident buffers
//! (`CABOOSE_FORMAT_MOD_REMOTE`, allocated through the render node's GBM backend,
//! guest/gpu/gbm), which the broker presents in the window (docs/gpu-buffers.md); a
//! per-window damage tracker redraws only what changed. On the computer's own device the
//! images are ordinary textures that nothing presents: the same rendering, with no phone
//! to show it on.
//!
//! A wl_shm buffer becomes a texture through its own staging buffer, uploading only the
//! client's damage (upload.rs). Client dma-bufs are imported as EGL images: their pixels
//! never pass through the computer. A phone-resident client buffer is never composed: its
//! pixels exist only in its own process's phone memory, so it is shown only when it covers
//! its window and the broker presents it there.
//!
//! Textures are sampled with nearest filtering when magnified: a window's picture is at
//! its buffer's own density, so its pixels map one to one, and a subsurface of a lower
//! density is scaled by whole pixels instead of blurred.

use crate::picture::Pool;
use crate::remote_buffers::MOD_REMOTE;
use smithay::backend::allocator::dmabuf::{AsDmabuf, Dmabuf};
use smithay::backend::allocator::gbm::{GbmAllocator, GbmBufferFlags, GbmDevice};
use smithay::backend::allocator::{Fourcc, Modifier};
use smithay::utils::DeviceFd;
use smithay::backend::egl::{EGLContext, EGLDevice, EGLDisplay};
use smithay::backend::renderer::damage::OutputDamageTracker;
use smithay::backend::renderer::element::surface::WaylandSurfaceRenderElement;
use smithay::backend::renderer::element::texture::TextureRenderElement;
use smithay::backend::renderer::element::{Id, Kind};
use smithay::backend::renderer::gles::format::{fourcc_to_gl_formats, gl_bpp};
use smithay::backend::renderer::gles::{ffi, GlesRenderer, GlesTexture};
use smithay::backend::renderer::sync::SyncPoint;
use smithay::backend::renderer::utils::{CommitCounter, RendererSurfaceStateUserData};
use smithay::backend::renderer::{
    Bind, Color32F, Offscreen, Renderer as _, Texture as _, TextureFilter,
};
use smithay::reexports::wayland_server::backend::ObjectId;
use smithay::reexports::wayland_server::protocol::wl_buffer::WlBuffer;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::reexports::wayland_server::{Resource, Weak};
use smithay::utils::{Logical, Physical, Point, Size, Transform};
use smithay::wayland::compositor::{with_surface_tree_downward, SurfaceData, TraversalAction};
use std::collections::HashMap;

smithay::backend::renderer::element::render_elements! {
    /// One surface of a window's tree.
    pub WindowElement<=GlesRenderer>;
    /// A client dma-buf or a single-pixel buffer, imported by Smithay.
    Surface=WaylandSurfaceRenderElement<GlesRenderer>,
    /// A wl_shm buffer, uploaded through its staging buffer.
    Shm=TextureRenderElement<GlesTexture>,
}

/// Environment variables the compositor sets for its own GPU stack, never passed on.
pub const OWN_ENV: &[&str] = &[
    "GALLIUM_DRIVER",
    "CABOOSE_GPU_ROUTING",
    "NODEVICE_SELECT",
    "VK_ADD_DRIVER_FILES",
    "CABOOSE_GFXSTREAM_SOCKET",
    "CABOOSE_GFXSTREAM_SURFACE_SOCKET",
    "CABOOSE_GPU_ON_LOSS",
];

/// A surface's texture of its wl_shm buffer, and up to which commit it holds.
struct ShmTexture {
    texture: GlesTexture,
    format: Fourcc,
    size: (i32, i32),
    seen: CommitCounter,
    surface: Weak<WlSurface>,
}

/// A client buffer's staging buffer, laid out as its shared memory is.
struct Staging {
    pbo: u32,
    len: usize,
    buffer: Weak<WlBuffer>,
}

/// The renderer: one EGL context and what lives in it.
pub struct Gpu {
    renderer: GlesRenderer,
    allocator: Option<GbmAllocator<DeviceFd>>,
    /// Window images can be phone-resident buffers, which the broker presents.
    remote: bool,
    /// The OpenGL renderer string, for the log.
    pub name: String,
    textures: HashMap<ObjectId, ShmTexture>,
    staging: HashMap<ObjectId, Staging>,
    /// Bytes copied into staging buffers, and texture uploads made.
    pub uploaded_bytes: u64,
    pub uploads: u64,
}

/// What rendering a window produced.
pub enum Rendered {
    /// Every image is with the broker: the window waits for one to come back.
    NoRoom,
    /// Nothing changed.
    Unchanged,
    /// Image `index` holds the new frame once `sync` is reached.
    Frame { index: usize, sync: SyncPoint, damaged_px: u64 },
    /// A new frame in an image on the computer, which nothing presents.
    Kept { damaged_px: u64 },
}

/// A window's images and the damage tracker that knows what each holds.
pub struct Canvas {
    generation: u64,
    /// Unique among the compositor's canvases: a release names the canvas it is for.
    serial: u64,
    size: Size<i32, Physical>,
    scale: f64,
    alpha: bool,
    damage: OutputDamageTracker,
    pool: Pool<Image>,
}

/// A window image: a phone-resident buffer, or a texture on the computer's device.
pub enum Image {
    Remote(Dmabuf),
    Local(GlesTexture),
}

impl std::fmt::Debug for Canvas {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Canvas")
            .field("serial", &self.serial)
            .field("size", &self.size)
            .field("scale", &self.scale)
            .field("alpha", &self.alpha)
            .finish_non_exhaustive()
    }
}

impl Canvas {
    pub fn new(generation: u64, serial: u64, size: Size<i32, Physical>, scale: f64, alpha: bool) -> Self {
        let damage = OutputDamageTracker::new(size, scale, Transform::Normal);
        Self { generation, serial, size, scale, alpha, damage, pool: Pool::default() }
    }

    pub fn matches(&self, generation: u64, size: Size<i32, Physical>, scale: f64, alpha: bool) -> bool {
        self.generation == generation && self.size == size && self.scale == scale && self.alpha == alpha
    }

    pub fn serial(&self) -> u64 {
        self.serial
    }

    pub fn has_room(&self) -> bool {
        self.pool.has_room()
    }

    pub fn release(&mut self, index: usize) {
        self.pool.release(index);
    }

    /// The image's phone-resident buffer, if it is one.
    pub fn remote_image(&self, index: usize) -> Option<&Dmabuf> {
        match self.pool.image(index) {
            Image::Remote(dmabuf) => Some(dmabuf),
            Image::Local(_) => None,
        }
    }
}

/// Zink's descriptor mode on every device: the phone's GPU has no descriptor buffers.
pub const ZINK_DESCRIPTORS: &str = "lazy";

/// A process-wide setting for the GPU stack, made before any thread starts: the process
/// environment is read by Mesa and the Vulkan loader, not passed to them.
pub fn configure_process(icd: Option<&std::path::Path>, stream: Option<&std::path::Path>, surface: Option<&std::path::Path>) {
    // SAFETY (set_var): called from main before the compositor starts any thread.
    std::env::set_var("GALLIUM_DRIVER", "zink");
    std::env::set_var("CABOOSE_GPU_ROUTING", "1");
    std::env::set_var("NODEVICE_SELECT", "1");
    // Zink settles its descriptor mode once per process, on its first device: the
    // computer's CPU device, which has descriptor buffers, would fix it there and every
    // later renderer on the phone's GPU, which has none, would fail.
    std::env::set_var("ZINK_DESCRIPTORS", ZINK_DESCRIPTORS);
    if let (Some(icd), Some(stream), Some(surface)) = (icd, stream, surface) {
        std::env::set_var("VK_ADD_DRIVER_FILES", icd);
        std::env::set_var("CABOOSE_GFXSTREAM_SOCKET", stream);
        std::env::set_var("CABOOSE_GFXSTREAM_SURFACE_SOCKET", surface);
        // The compositor learns of the phone's departure from its broker and makes its
        // renderer again: its lost device stays quiet (completes everything, reports no
        // loss), so Zink never takes its device-loss paths, whose teardown does not end.
        std::env::set_var("CABOOSE_GPU_ON_LOSS", "quiet");
    }
}

/// The Gallium driver for a renderer on the computer alone (`Gpu::new_local`): llvmpipe draws
/// OpenGL ES on the CPU without Vulkan, so no Vulkan driver (and so no phone executor that
/// cannot answer, such as a suspended one) is loaded for it.
pub const LOCAL_GALLIUM_DRIVER: &str = "llvmpipe";

impl Gpu {
    /// A renderer on the computer alone, for while no phone executor serves the compositor:
    /// screenshots and the agents' tools still see real pictures with the phone away.
    pub fn new_local(render_node: Option<&std::path::Path>) -> Result<Gpu, String> {
        // SAFETY (set_var): Mesa reads GALLIUM_DRIVER when the EGL display is made, on this
        // (the compositor's main) thread; the previous renderer and its threads are dropped.
        std::env::set_var("GALLIUM_DRIVER", LOCAL_GALLIUM_DRIVER);
        let gpu = Gpu::new(render_node);
        std::env::set_var("GALLIUM_DRIVER", "zink");
        gpu
    }

    /// A new renderer on whatever device Zink finds first: the phone's GPU when an executor
    /// is attached, else the computer's CPU device. `render_node` is the computer's vgem
    /// node, on which phone-resident buffers are allocated.
    pub fn new(render_node: Option<&std::path::Path>) -> Result<Gpu, String> {
        let device = EGLDevice::enumerate()
            .map_err(|e| format!("EGL devices: {e}"))?
            .find(|d| d.is_software())
            .ok_or("no EGL software device")?;
        // SAFETY: the device is valid for the display's lifetime, which owns it.
        let display = unsafe { EGLDisplay::new(device) }.map_err(|e| format!("EGL display: {e}"))?;
        let context = EGLContext::new(&display).map_err(|e| format!("EGL context: {e}"))?;
        // SAFETY: the context is new and current on no other thread.
        let mut renderer = unsafe { GlesRenderer::new(context) }.map_err(|e| format!("OpenGL ES: {e}"))?;
        renderer.upscale_filter(TextureFilter::Nearest).map_err(|e| e.to_string())?;
        renderer.downscale_filter(TextureFilter::Linear).map_err(|e| e.to_string())?;
        let name = renderer
            .with_context(|gl| unsafe {
                let s = gl.GetString(ffi::RENDERER);
                if s.is_null() {
                    String::new()
                } else {
                    std::ffi::CStr::from_ptr(s.cast()).to_string_lossy().into_owned()
                }
            })
            .unwrap_or_default();
        let remote_formats = [Fourcc::Argb8888, Fourcc::Xrgb8888].iter().all(|code| {
            display.dmabuf_render_formats().iter().any(|f| f.code == *code && u64::from(f.modifier) == MOD_REMOTE)
        });
        // On the computer's own device (the routing layer's CPU device, which the driver's
        // dma-buf formats can still reach) nothing registers the buffers it would draw.
        let on_computer = name.contains(crate::present::COMPUTER_DEVICE);
        let allocator = if remote_formats && !on_computer { render_node.and_then(open_allocator) } else { None };
        let remote = allocator.is_some();
        Ok(Gpu {
            renderer,
            allocator,
            remote,
            name,
            textures: HashMap::new(),
            staging: HashMap::new(),
            uploaded_bytes: 0,
            uploads: 0,
        })
    }

    /// Whether window images are phone-resident, so there is something to present.
    pub fn presents(&self) -> bool {
        self.remote
    }

    /// The dma-buf formats clients may hand over for composition.
    pub fn dmabuf_formats(&self) -> Vec<smithay::backend::allocator::Format> {
        use smithay::backend::renderer::ImportDma;
        self.renderer.dmabuf_formats().into_iter().collect()
    }

    pub fn import_dmabuf(&mut self, dmabuf: &Dmabuf) -> bool {
        use smithay::backend::renderer::ImportDma;
        self.renderer.import_dmabuf(dmabuf, None).is_ok()
    }

    /// Forgets the textures and staging buffers of surfaces and buffers that are gone.
    pub fn prune(&mut self) {
        self.textures.retain(|_, t| t.surface.upgrade().is_ok());
        let dead: Vec<ObjectId> =
            self.staging.iter().filter(|(_, s)| s.buffer.upgrade().is_err()).map(|(id, _)| id.clone()).collect();
        for id in dead {
            if let Some(staging) = self.staging.remove(&id) {
                let pbo = staging.pbo;
                let _ = self.renderer.with_context(|gl| unsafe { gl.DeleteBuffers(1, &pbo) });
            }
        }
    }

    /// Renders `surface`'s tree, its window geometry origin at `origin` (surface-local
    /// logical), into the next free image of `canvas`.
    pub fn render(&mut self, canvas: &mut Canvas, surface: &WlSurface, origin: Point<i32, Logical>) -> Result<Rendered, String> {
        let (size, alpha) = (canvas.size, canvas.alpha);
        let (allocator, renderer) = (&mut self.allocator, &mut self.renderer);
        let acquired = canvas.pool.acquire(|| match allocator.as_mut() {
            Some(allocator) => allocate(allocator, size, alpha).map(Image::Remote),
            None => renderer
                .create_buffer(Fourcc::Abgr8888, (size.w, size.h).into())
                .map(Image::Local)
                .map_err(|e| format!("window image {}x{}: {e}", size.w, size.h)),
        })?;
        let Some((index, age)) = acquired else { return Ok(Rendered::NoRoom) };
        let elements = self.elements(surface, origin, canvas.scale);
        let clear = if alpha { Color32F::TRANSPARENT } else { Color32F::BLACK };
        let result = (|| {
            let mut target = match canvas.pool.image_mut(index) {
                Image::Remote(dmabuf) => self.renderer.bind(dmabuf),
                Image::Local(texture) => self.renderer.bind(texture),
            }
            .map_err(|e| format!("bind the window image: {e}"))?;
            let rendered = canvas
                .damage
                .render_output(&mut self.renderer, &mut target, age, &elements, clear)
                .map_err(|e| format!("render: {e:?}"))?;
            let damaged_px = rendered
                .damage
                .map(|d| d.iter().map(|r| r.size.w.max(0) as u64 * r.size.h.max(0) as u64).sum())
                .unwrap_or(0);
            Ok::<_, String>((damaged_px, rendered.sync))
        })();
        match result {
            Ok((0, _)) if age > 0 => {
                canvas.pool.unchanged(index);
                Ok(Rendered::Unchanged)
            }
            Ok((damaged_px, sync)) => {
                canvas.pool.rendered(index);
                Ok(Rendered::Frame { index, sync, damaged_px })
            }
            Err(e) => {
                canvas.pool.forget(index);
                Err(e)
            }
        }
    }

    /// A picture of `surface`'s tree at `scale`, cropped to the window geometry at `origin`
    /// (surface-local logical), `size` physical pixels: RGBA, rows top to bottom.
    pub fn capture(&mut self, surface: &WlSurface, origin: Point<i32, Logical>, size: Size<i32, Physical>, scale: f64) -> Result<Vec<u8>, String> {
        let elements = self.elements(surface, origin, scale);
        let buffer_size = Size::<i32, smithay::utils::Buffer>::from((size.w, size.h));
        let mut texture: GlesTexture =
            self.renderer.create_buffer(Fourcc::Abgr8888, buffer_size).map_err(|e| format!("picture texture: {e}"))?;
        let mut target = self.renderer.bind(&mut texture).map_err(|e| format!("bind the picture: {e}"))?;
        let mut damage = OutputDamageTracker::new(size, scale, Transform::Normal);
        damage
            .render_output(&mut self.renderer, &mut target, 0, &elements, Color32F::BLACK)
            .map_err(|e| format!("render: {e:?}"))?
            .sync
            .wait()
            .map_err(|_| "the picture's rendering was interrupted".to_string())?;
        drop(target);
        // Read straight into memory: the renderer's own readback goes through a pixel pack
        // buffer, which its OpenGL ES 2 context does not have. Smithay draws offscreen
        // targets top row first, as it does a dma-buf for scanout, so the rows read back
        // are already top to bottom.
        let len = size.w as usize * 4 * size.h as usize;
        let mut rgba = vec![0u8; len];
        let tex = texture.tex_id();
        let complete = self
            .renderer
            .with_context(|gl| unsafe {
                let mut fbo = 0;
                gl.GenFramebuffers(1, &mut fbo);
                gl.BindFramebuffer(ffi::FRAMEBUFFER, fbo);
                gl.FramebufferTexture2D(ffi::FRAMEBUFFER, ffi::COLOR_ATTACHMENT0, ffi::TEXTURE_2D, tex, 0);
                let complete = gl.CheckFramebufferStatus(ffi::FRAMEBUFFER) == ffi::FRAMEBUFFER_COMPLETE;
                if complete {
                    gl.PixelStorei(ffi::PACK_ALIGNMENT, 4);
                    gl.ReadPixels(0, 0, size.w, size.h, ffi::RGBA, ffi::UNSIGNED_BYTE, rgba.as_mut_ptr().cast());
                }
                gl.BindFramebuffer(ffi::FRAMEBUFFER, 0);
                gl.DeleteFramebuffers(1, &fbo);
                complete
            })
            .map_err(|e| format!("read the picture: {e}"))?;
        if !complete {
            return Err("read the picture: its framebuffer is incomplete".into());
        }
        Ok(rgba)
    }

    /// The elements of a surface tree, topmost first, with the window geometry origin at
    /// the picture's top left.
    fn elements(&mut self, surface: &WlSurface, origin: Point<i32, Logical>, scale: f64) -> Vec<WindowElement> {
        let start: Point<f64, Physical> = origin.to_f64().to_physical(scale).to_i32_round::<i32>().to_f64();
        let start = Point::<f64, Physical>::from((-start.x, -start.y));
        let mut out = Vec::new();
        let Gpu { renderer, textures, staging, uploaded_bytes, uploads, .. } = self;
        with_surface_tree_downward(
            surface,
            start,
            |_, states, location| {
                let view = states.data_map.get::<RendererSurfaceStateUserData>().and_then(|d| d.lock().unwrap().view());
                match view {
                    Some(view) => TraversalAction::DoChildren(*location + view.offset.to_f64().to_physical(scale)),
                    None => TraversalAction::SkipChildren,
                }
            },
            |surface, states, location| {
                let Some(data) = states.data_map.get::<RendererSurfaceStateUserData>() else { return };
                let Some(view) = data.lock().unwrap().view() else { return };
                let location = *location + view.offset.to_f64().to_physical(scale);
                let shm = data
                    .lock()
                    .unwrap()
                    .buffer()
                    .is_some_and(|b| matches!(smithay::backend::renderer::buffer_type(b), Some(smithay::backend::renderer::BufferType::Shm)));
                tracing::trace!(surface = ?surface.id(), ?location, shm, src = ?view.src, dst = ?view.dst, "window element");
                if shm {
                    match shm_element(renderer, textures, staging, surface, states, location) {
                        Ok(Some((element, bytes))) => {
                            *uploaded_bytes += bytes;
                            *uploads += u64::from(bytes > 0);
                            out.push(WindowElement::Shm(element));
                        }
                        Ok(None) => {}
                        Err(e) => tracing::warn!("shm upload: {e}"),
                    }
                    return;
                }
                // A client's phone-resident buffer has no pixels in this process: importing it
                // here gets new phone memory nobody drew into, which shows as noise. Only the
                // broker can show it, presented straight into the window (docs/gpu-buffers.md),
                // so a composed window leaves it out.
                let remote = data.lock().unwrap().buffer().is_some_and(|b|
                    smithay::wayland::dmabuf::get_dmabuf(b).is_ok_and(crate::remote_buffers::is_remote));
                if remote {
                    tracing::trace!(surface = ?surface.id(), "remote buffer left out of a composed window");
                    return;
                }
                match WaylandSurfaceRenderElement::from_surface(renderer, surface, states, location, 1.0, Kind::Unspecified) {
                    Ok(Some(element)) => out.push(WindowElement::Surface(element)),
                    Ok(None) => {}
                    Err(e) => tracing::debug!("surface import: {e}"),
                }
            },
            |_, _, _| true,
        );
        out
    }
}

fn open_allocator(path: &std::path::Path) -> Option<GbmAllocator<DeviceFd>> {
    use std::os::unix::fs::OpenOptionsExt;
    let file = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .custom_flags(libc::O_CLOEXEC)
        .open(path)
        .map_err(|e| tracing::warn!("render node {}: {e}", path.display()))
        .ok()?;
    let fd = DeviceFd::from(std::os::fd::OwnedFd::from(file));
    let device = GbmDevice::new(fd).map_err(|e| tracing::warn!("GBM on {}: {e}", path.display())).ok()?;
    Some(GbmAllocator::new(device, GbmBufferFlags::RENDERING))
}

/// A phone-resident buffer for a window image: ARGB for a window with alpha, else XRGB.
fn allocate(allocator: &mut GbmAllocator<DeviceFd>, size: Size<i32, Physical>, alpha: bool) -> Result<Dmabuf, String> {
    let fourcc = if alpha { Fourcc::Argb8888 } else { Fourcc::Xrgb8888 };
    let buffer = allocator
        .create_buffer_with_flags(size.w as u32, size.h as u32, fourcc, &[Modifier::from(MOD_REMOTE)], GbmBufferFlags::RENDERING)
        .map_err(|e| format!("window image {}x{}: {e}", size.w, size.h))?;
    let dmabuf = buffer.export().map_err(|e| format!("window image export: {e}"))?;
    if !crate::remote_buffers::is_remote(&dmabuf) {
        return Err("the GBM backend made a buffer that is not phone-resident".into());
    }
    Ok(dmabuf)
}

/// A wl_shm surface's element, its texture brought up to date through the buffer's staging
/// buffer, and the bytes this upload copied.
fn shm_element(
    renderer: &mut GlesRenderer,
    textures: &mut HashMap<ObjectId, ShmTexture>,
    staging: &mut HashMap<ObjectId, Staging>,
    surface: &WlSurface,
    states: &SurfaceData,
    location: Point<f64, Physical>,
) -> Result<Option<(TextureRenderElement<GlesTexture>, u64)>, String> {
    let Some(data) = states.data_map.get::<RendererSurfaceStateUserData>() else { return Ok(None) };
    let data = data.lock().unwrap();
    let (Some(buffer), Some(view)) = (data.buffer(), data.view()) else { return Ok(None) };
    let buffer: &WlBuffer = buffer;
    let surface_id = surface.id();
    let commit = data.current_commit();
    let known = textures.get(&surface_id).map(|t| (t.format, t.size, t.seen));
    let damage = |seen: CommitCounter| -> Vec<(i32, i32, i32, i32)> {
        data.damage_since(Some(seen)).iter().map(|r| (r.loc.x, r.loc.y, r.size.w, r.size.h)).collect()
    };
    let result = smithay::wayland::shm::with_buffer_contents(buffer, |ptr, len, info| -> Result<(GlesTexture, u64, Fourcc), String> {
        let fourcc = smithay::wayland::shm::shm_format_to_fourcc(info.format).ok_or("unsupported shm format")?;
        let (internal, format, type_) = fourcc_to_gl_formats(fourcc).ok_or("unsupported shm format")?;
        let bpp = gl_bpp(format, type_).ok_or("unsupported shm format")? / 8;
        let (width, height, stride) = (info.width, info.height, info.stride as usize);
        if width <= 0 || height <= 0 || stride % bpp != 0 {
            return Err("unsupported shm layout".into());
        }
        let offset = info.offset as usize;
        if offset + (height as usize - 1) * stride + width as usize * bpp > len {
            return Err("shm buffer smaller than its layout".into());
        }
        // SAFETY: with_buffer_contents maps `len` bytes of the pool at `ptr` for this
        // closure and catches SIGBUS if the client truncates it.
        let pixels = unsafe { std::slice::from_raw_parts(ptr.add(offset), len - offset) };
        let reuse = known.filter(|(f, s, _)| *f == fourcc && *s == (width, height));
        let rects = reuse.map(|(_, _, seen)| damage(seen));
        let uploads = crate::upload::uploads(rects.as_deref(), width, height, stride, bpp);
        let existing = reuse.and_then(|_| textures.get(&surface_id)).map(|t| t.texture.clone());
        let pbo_len = (height as usize - 1) * stride + width as usize * bpp;
        let buffer_id = buffer.id();
        let old_pbo = staging.get(&buffer_id).filter(|s| s.len != pbo_len).map(|s| s.pbo);
        let current_pbo = staging.get(&buffer_id).filter(|s| s.len == pbo_len).map(|s| s.pbo);
        let mut copied = 0u64;
        let (tex, pbo) = renderer
            .with_context(|gl| unsafe {
                if let Some(old) = old_pbo {
                    gl.DeleteBuffers(1, &old);
                }
                let pbo = match current_pbo {
                    Some(pbo) => {
                        gl.BindBuffer(ffi::PIXEL_UNPACK_BUFFER, pbo);
                        pbo
                    }
                    None => {
                        let mut pbo = 0;
                        gl.GenBuffers(1, &mut pbo);
                        gl.BindBuffer(ffi::PIXEL_UNPACK_BUFFER, pbo);
                        gl.BufferData(ffi::PIXEL_UNPACK_BUFFER, pbo_len as isize, std::ptr::null(), ffi::STREAM_DRAW);
                        pbo
                    }
                };
                let tex = match &existing {
                    Some(t) => t.tex_id(),
                    None => {
                        let mut tex = 0;
                        gl.GenTextures(1, &mut tex);
                        gl.BindTexture(ffi::TEXTURE_2D, tex);
                        gl.TexParameteri(ffi::TEXTURE_2D, ffi::TEXTURE_WRAP_S, ffi::CLAMP_TO_EDGE as i32);
                        gl.TexParameteri(ffi::TEXTURE_2D, ffi::TEXTURE_WRAP_T, ffi::CLAMP_TO_EDGE as i32);
                        gl.TexImage2D(ffi::TEXTURE_2D, 0, internal as i32, width, height, 0, format, type_, std::ptr::null());
                        tex
                    }
                };
                // Every rectangle into the staging buffer first, then every copy into the
                // texture, so no mapping waits for a copy issued just before it.
                let mut mapped_all = true;
                for up in &uploads {
                    let mapped = gl.MapBufferRange(
                        ffi::PIXEL_UNPACK_BUFFER,
                        up.offset as isize,
                        up.len as isize,
                        ffi::MAP_WRITE_BIT | ffi::MAP_FLUSH_EXPLICIT_BIT,
                    );
                    if mapped.is_null() {
                        mapped_all = false;
                        break;
                    }
                    let mapped = std::slice::from_raw_parts_mut(mapped.cast::<u8>(), up.len);
                    crate::upload::copy_rows(up, pixels, stride, bpp, mapped);
                    gl.FlushMappedBufferRange(ffi::PIXEL_UNPACK_BUFFER, 0, up.len as isize);
                    gl.UnmapBuffer(ffi::PIXEL_UNPACK_BUFFER);
                    copied += (up.w as usize * bpp * up.h as usize) as u64;
                }
                if mapped_all {
                    gl.BindTexture(ffi::TEXTURE_2D, tex);
                    gl.PixelStorei(ffi::UNPACK_ROW_LENGTH, (stride / bpp) as i32);
                    for up in &uploads {
                        gl.TexSubImage2D(ffi::TEXTURE_2D, 0, up.x, up.y, up.w, up.h, format, type_, up.offset as *const _);
                    }
                    gl.PixelStorei(ffi::UNPACK_ROW_LENGTH, 0);
                }
                gl.BindTexture(ffi::TEXTURE_2D, 0);
                gl.BindBuffer(ffi::PIXEL_UNPACK_BUFFER, 0);
                (mapped_all.then_some(tex), pbo)
            })
            .map_err(|e| format!("shm upload: {e}"))?;
        staging.insert(buffer_id, Staging { pbo, len: pbo_len, buffer: buffer.downgrade() });
        let tex = tex.ok_or("the staging buffer could not be mapped")?;
        let texture = match existing {
            Some(texture) => texture,
            // SAFETY: `tex` is a texture of this renderer's context, owned from here on.
            None => unsafe { GlesTexture::from_raw(renderer, Some(internal), !has_alpha(fourcc), tex, (width, height).into()) },
        };
        Ok((texture, copied, fourcc))
    });
    let (texture, copied, format) = match result {
        Ok(Ok(done)) => done,
        Ok(Err(e)) => return Err(e),
        Err(e) => return Err(format!("shm buffer: {e:?}")),
    };
    textures.insert(
        surface_id,
        ShmTexture {
            texture: texture.clone(),
            format,
            size: (texture.width() as i32, texture.height() as i32),
            seen: commit,
            surface: surface.downgrade(),
        },
    );
    let element = TextureRenderElement::from_texture_with_damage(
        Id::from_wayland_resource(surface),
        renderer.context_id(),
        location,
        texture,
        data.buffer_scale(),
        data.buffer_transform(),
        None,
        Some(view.src),
        Some(view.dst),
        None,
        data.damage(),
        Kind::Unspecified,
    );
    Ok(Some((element, copied)))
}

fn has_alpha(fourcc: Fourcc) -> bool {
    !matches!(fourcc, Fourcc::Xrgb8888 | Fourcc::Xbgr8888 | Fourcc::Xbgr2101010 | Fourcc::Xbgr16161616f)
}

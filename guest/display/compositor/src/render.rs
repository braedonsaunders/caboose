//! Turns one window's surface tree into one picture.
//!
//! The compositor composites nothing across windows: each window (toplevel, popup or
//! X11 window) is rendered alone, cropped to its window geometry, into its own buffer,
//! with a per-window damage tracker so an unchanged window costs nothing. With the
//! pixman renderer the buffer is the encoder's input image itself, so a software or
//! NVENC encode reads the pixels where they were composed.
//!
//! Most windows are one surface with one wl_shm buffer that already is the picture.
//! For those, [`direct_copy`] skips composition and copies just the client's damage
//! from the shared memory into the image.

use crate::encode::CpuImage;
use smithay::backend::renderer::damage::OutputDamageTracker;
use smithay::backend::renderer::element::surface::{render_elements_from_surface_tree, WaylandSurfaceRenderElement};
use smithay::backend::renderer::element::Kind;
use smithay::backend::renderer::pixman::PixmanRenderer;
use smithay::backend::renderer::utils::{with_renderer_surface_state, CommitCounter, RendererSurfaceStateUserData};
use smithay::backend::renderer::{Bind, Color32F};
use smithay::reexports::pixman;
use smithay::reexports::wayland_server::protocol::wl_shm;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::utils::{Logical, Physical, Point, Rectangle, Size, Transform};
use smithay::wayland::compositor::{with_surface_tree_downward, TraversalAction};

/// The renderer every window is drawn with.
pub enum Renderer {
    Pixman(PixmanRenderer),
}

impl Renderer {
    pub fn name(&self) -> &'static str {
        match self {
            Renderer::Pixman(_) => "pixman",
        }
    }
}

/// What the stream gets back from a render.
pub enum Rendered {
    /// Nothing changed since the last picture.
    Unchanged,
    /// A new picture in the stream's image; these rectangles (picture pixels) changed.
    Picture(Vec<caboose_display_protocol::Rect>),
}

/// Per-window rendering state: the damage tracker for the current size and scale.
pub struct Canvas {
    size: Size<i32, Physical>,
    scale: f64,
    damage: OutputDamageTracker,
    /// The image the damage tracker's history refers to. A different image (after a
    /// resize, or a new one) starts from a full redraw.
    image_id: u64,
    age: usize,
}

impl Canvas {
    pub fn new(size: Size<i32, Physical>, scale: f64) -> Self {
        Self { size, scale, damage: OutputDamageTracker::new(size, scale, Transform::Normal), image_id: 0, age: 0 }
    }

    /// Forgets the image's history (it was written by something else), so the next
    /// render redraws everything.
    pub fn invalidate(&mut self) {
        self.age = 0;
    }

    pub fn matches(&self, size: Size<i32, Physical>, scale: f64) -> bool {
        self.size == size && self.scale == scale
    }

    /// Renders `surface`'s tree, with the window geometry origin at `geometry_origin`
    /// (surface-local logical coordinates), into `image`, whose top-left `size` region
    /// receives the picture.
    pub fn render(
        &mut self,
        renderer: &mut Renderer,
        surface: &WlSurface,
        geometry_origin: Point<i32, smithay::utils::Logical>,
        image: &mut CpuImage,
        image_id: u64,
    ) -> Result<Rendered, String> {
        if image.width < self.size.w as u32 || image.height < self.size.h as u32 {
            return Err("image smaller than the canvas".into());
        }
        if image_id != self.image_id {
            self.image_id = image_id;
            self.age = 0;
        }
        let origin = geometry_origin.to_f64().to_physical(self.scale);
        let location: Point<i32, Physical> = Point::<f64, Physical>::from((-origin.x, -origin.y)).to_i32_round();
        match renderer {
            Renderer::Pixman(r) => {
                let elements: Vec<WaylandSurfaceRenderElement<PixmanRenderer>> =
                    render_elements_from_surface_tree(r, surface, location, self.scale, 1.0, Kind::Unspecified);
                // SAFETY: the image's buffer outlives this pixman image, which is dropped
                // at the end of this block, and nothing else touches the buffer meanwhile.
                let mut target = unsafe {
                    pixman::Image::from_raw_mut(
                        pixman::FormatCode::X8R8G8B8,
                        self.size.w as usize,
                        self.size.h as usize,
                        image.data.as_mut_ptr() as *mut u32,
                        image.stride,
                        false,
                    )
                }
                .map_err(|_| "pixman could not wrap the image".to_string())?;
                let mut framebuffer = r.bind(&mut target).map_err(|e| e.to_string())?;
                let result = self
                    .damage
                    .render_output(r, &mut framebuffer, self.age, &elements, Color32F::BLACK)
                    .map_err(|e| format!("{e:?}"))?;
                let damage: Vec<_> = result
                    .damage
                    .map(|d| {
                        d.iter()
                            .map(|r| caboose_display_protocol::Rect::new(r.loc.x, r.loc.y, r.size.w, r.size.h))
                            .collect()
                    })
                    .unwrap_or_default();
                drop(framebuffer);
                self.age = 1;
                Ok(if damage.is_empty() { Rendered::Unchanged } else { Rendered::Picture(damage) })
            }
        }
    }
}

/// Where a directly streamed window is: what its last picture was taken into
/// (`image_id`, or [`SHM_IN_PLACE`] when the encoder read the buffer in place) and up to
/// which commit.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DirectState {
    pub image_id: u64,
    pub commit: CommitCounter,
}

/// `DirectState::image_id` for pictures the encoder read straight from the buffer.
pub const SHM_IN_PLACE: u64 = u64::MAX;

/// A window that is one surface with one XRGB/ARGB wl_shm buffer, unscaled and
/// untransformed: its picture is the buffer's region at `origin`.
pub struct Direct {
    pub buffer: smithay::backend::renderer::utils::Buffer,
    pub origin: (i32, i32),
    pub commit: CommitCounter,
    /// What changed since the commit asked for (all of it without one), picture pixels.
    pub damage: Vec<caboose_display_protocol::Rect>,
}

/// Whether `surface` can be streamed straight from its buffer, cropped to the window
/// geometry `local` (surface-local logical) at `size`; `None` means it must be composed.
pub fn direct(
    surface: &WlSurface,
    local: Rectangle<i32, Logical>,
    size: Size<i32, Physical>,
    since: Option<CommitCounter>,
) -> Option<Direct> {
    // One surface with a buffer: subsurfaces need composition.
    let mut with_buffers = 0;
    with_surface_tree_downward(
        surface,
        (),
        |_, _, _| TraversalAction::DoChildren(()),
        |_, states, _| {
            // The tree walk holds each surface's state; read it from there (taking the
            // lock again through with_renderer_surface_state would deadlock).
            let has_buffer = states
                .data_map
                .get::<RendererSurfaceStateUserData>()
                .is_some_and(|d| d.lock().unwrap().buffer().is_some());
            if has_buffer {
                with_buffers += 1;
            }
        },
        |_, _, _| true,
    );
    if with_buffers != 1 {
        return None;
    }
    let (buffer, scale, commit, damage) = with_renderer_surface_state(surface, |r| {
        let buffer = r.buffer()?.clone();
        let view = r.view()?;
        let logical = r.buffer_size()?;
        // No viewport scaling or cropping, no transform.
        let unscaled =
            view.src == Rectangle::from_size(logical.to_f64()) && view.dst == logical && view.offset == (0, 0).into();
        if !unscaled || r.buffer_transform() != Transform::Normal {
            return None;
        }
        let damage: Vec<_> = r.damage_since(since).iter().copied().collect();
        Some((buffer, r.buffer_scale(), r.current_commit(), damage))
    })??;
    if size.w != local.size.w * scale || size.h != local.size.h * scale {
        return None; // the stream renders at another density
    }
    let origin = (local.loc.x * scale, local.loc.y * scale);
    let fits = smithay::wayland::shm::with_buffer_contents(&buffer, |_, len, data| {
        matches!(data.format, wl_shm::Format::Xrgb8888 | wl_shm::Format::Argb8888)
            && origin.0 >= 0
            && origin.1 >= 0
            && origin.0 + size.w <= data.width
            && origin.1 + size.h <= data.height
            && data.width * 4 <= data.stride
            && data.offset as usize + data.stride as usize * data.height as usize <= len
    });
    if !matches!(fits, Ok(true)) {
        return None;
    }
    let crop = Rectangle::<i32, smithay::utils::Buffer>::new(origin.into(), (size.w, size.h).into());
    let damage = damage
        .iter()
        .filter_map(|d| d.intersection(crop))
        .map(|r| caboose_display_protocol::Rect::new(r.loc.x - origin.0, r.loc.y - origin.1, r.size.w, r.size.h))
        .collect();
    Some(Direct { buffer, origin, commit, damage })
}

/// Copies a direct window's damage from its buffer into `image`.
pub fn copy_direct(d: &Direct, image: &mut CpuImage) -> Result<(), String> {
    let copied = smithay::wayland::shm::with_buffer_contents(&d.buffer, |ptr, len, data| {
        let stride = data.stride as usize;
        // SAFETY: with_buffer_contents maps `len` bytes of the pool at `ptr` for the
        // duration of this closure and catches SIGBUS if the client truncates it.
        let pool = unsafe { std::slice::from_raw_parts(ptr, len) };
        let pixels = &pool[data.offset as usize..];
        for r in &d.damage {
            let (x0, w) = ((d.origin.0 + r.x) as usize, r.w as usize);
            for row in r.y..r.y + r.h {
                let src = (d.origin.1 + row) as usize * stride + x0 * 4;
                let dst = row as usize * image.stride + r.x as usize * 4;
                image.data[dst..dst + w * 4].copy_from_slice(&pixels[src..src + w * 4]);
            }
        }
    });
    copied.map_err(|e| format!("shm buffer: {e:?}"))
}

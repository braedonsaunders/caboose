//! Turns one window's surface tree into one picture.
//!
//! The compositor composites nothing across windows: each window (toplevel, popup or
//! X11 window) is rendered alone, cropped to its window geometry, into its own buffer,
//! with a per-window damage tracker so an unchanged window costs nothing. With the
//! pixman renderer the buffer is the encoder's input image itself, so a software or
//! NVENC encode reads the pixels where they were composed.

use crate::encode::CpuImage;
use smithay::backend::renderer::damage::OutputDamageTracker;
use smithay::backend::renderer::element::surface::{render_elements_from_surface_tree, WaylandSurfaceRenderElement};
use smithay::backend::renderer::element::Kind;
use smithay::backend::renderer::pixman::PixmanRenderer;
use smithay::backend::renderer::{Bind, Color32F};
use smithay::reexports::pixman;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use smithay::utils::{Physical, Point, Size, Transform};

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

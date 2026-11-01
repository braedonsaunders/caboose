//! Each window's picture reaches the phone as one GPU image (docs/gpu-buffers.md).
//!
//! - A window whose tree is one phone-resident client buffer covering its geometry presents
//!   that buffer (`State::present_remote_buffer`, state.rs).
//! - A window whose application draws into its own phone surface (a Vulkan swapchain bound
//!   to its Wayland surface or X11 window) presents nothing here.
//! - Every other window is rendered by the compositor into its own phone-resident images
//!   (render.rs) and presented as a buffer window of the compositor's own process, popups
//!   and override-redirect X11 windows included, with their alpha.
//!
//! Windows are rendered while a client is connected. On the phone's GPU (its executor
//! ready) a frame is presented once its GPU work has finished, which the compositor learns
//! from a fence without waiting for it. On the computer's own device, before a phone's
//! executor is ready, the frame stays in the compositor's image and nothing is presented.
//! When the executor changes, the renderer is made again and every window drawn again from
//! the buffers its clients last committed.

use crate::picture::Source;
use crate::remote_buffers::Held;
use crate::render::{Canvas, Gpu, Rendered};
use crate::state::State;
use caboose_display_protocol::WindowKind;
use smithay::backend::renderer::sync::SyncPoint;
use smithay::backend::renderer::utils::with_renderer_surface_state;
use smithay::reexports::calloop::generic::Generic;
use smithay::reexports::calloop::timer::{TimeoutAction, Timer};
use smithay::reexports::calloop::{Interest, Mode, PostAction};
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;
use std::time::{Duration, Instant};

/// How often a frame's fence is checked when it cannot be waited on as a file.
const FENCE_POLL: Duration = Duration::from_millis(1);
/// A frame whose GPU work has not finished by then is dropped unshown.
const FENCE_LIMIT: Duration = Duration::from_secs(5);
/// The shortest time between two remakes of the renderer after failed renders.
const RECOVERY_INTERVAL: Duration = Duration::from_secs(10);

/// The render scale of a window's root surface: buffer pixels per logical pixel, clamped
/// to [1, display scale]. A window's picture keeps its buffer's own density, so its pixels
/// are drawn one for one; the phone scales the picture to the window it shows.
pub fn surface_scale(surface: &WlSurface, display_scale: f64) -> f64 {
    let scale = with_renderer_surface_state(surface, |s| {
        let buffer = s.buffer_size()?;
        let logical = s.surface_size()?;
        (logical.w > 0).then(|| buffer.w as f64 * s.buffer_scale() as f64 / logical.w as f64)
    })
    .flatten()
    .unwrap_or(display_scale);
    picture_scale(scale, display_scale)
}

fn picture_scale(buffer_scale: f64, display_scale: f64) -> f64 {
    (buffer_scale.clamp(1.0, display_scale.max(1.0)) * 100.0).round() / 100.0
}

/// A picture's size in pixels for a window geometry of `w` x `h` logical pixels.
pub fn picture_size(w: i32, h: i32, scale: f64) -> (i32, i32) {
    ((w as f64 * scale).round().max(1.0) as i32, (h as f64 * scale).round().max(1.0) as i32)
}

impl State {
    /// Makes the renderer, again after the executor changed: the phone's GPU when one is
    /// ready, else the computer's. Every window is drawn again.
    pub fn rebuild_gpu(&mut self) {
        self.gpu_generation += 1;
        // The old renderer and every image of it go first: its device may be lost.
        self.gpu = None;
        for w in self.windows.iter_mut() {
            w.picture.repaint();
        }
        let started = Instant::now();
        match Gpu::new(self.render_node.as_deref()) {
            Ok(gpu) => {
                tracing::info!(
                    "renderer {}: {}{} in {} ms",
                    self.gpu_generation,
                    gpu.name,
                    if gpu.presents() { ", window images on the phone" } else { ", window images on the computer" },
                    started.elapsed().as_millis()
                );
                self.gpu = Some(gpu);
            }
            Err(e) => tracing::error!("no renderer: {e}"),
        }
    }

    /// The window's content changed in a way its damage does not say: draw it whole.
    pub fn repaint_window(&mut self, id: u64) {
        if let Some(w) = self.windows.get_mut(id) {
            w.picture.repaint();
        }
    }

    /// Whether windows are rendered now: a client is connected and, for images on the
    /// phone, its GPU executor is ready to present them.
    fn rendering(&self) -> bool {
        let Some(gpu) = self.gpu.as_ref() else { return false };
        self.session.as_ref().is_some_and(|s| s.ready)
            && (!gpu.presents() || self.gpu_grants.as_ref().is_some_and(|g| g.epoch_if_ready().is_some()))
    }

    /// Renders and presents every shown window that changed.
    pub fn render_windows(&mut self) {
        if !self.rendering() {
            return;
        }
        let owner_displays = self.session.as_ref().map(|s| s.owner_displays.clone()).unwrap_or_default();
        let mut failed = false;
        for id in self.windows.ids() {
            if self.game_shown(id) || self.gpu_grants.as_ref().is_some_and(|g| g.client_surface(id)) {
                continue;
            }
            let Some(w) = self.windows.get(id) else { continue };
            if w.announced.is_none()
                || !owner_displays.contains(&w.display)
                || !w.picture.dirty
                || w.picture.source == Source::Direct
                || w.picture.finishing.is_some()
            {
                continue;
            }
            let Some(root) = w.surface.wl_surface() else { continue };
            let local = w.local_geometry();
            if local.size.w <= 0 || local.size.h <= 0 {
                continue;
            }
            let scale = surface_scale(&root, self.displays.resolve(Some(w.display)).info.scale);
            let size = picture_size(local.size.w, local.size.h, scale).into();
            let alpha = w.kind == WindowKind::Popup;
            let generation = self.gpu_generation;
            let fresh = !w.picture.canvas.as_ref().is_some_and(|c| c.matches(generation, size, scale, alpha));
            if fresh {
                self.next_canvas += 1;
            }
            let serial = self.next_canvas;
            let Some(gpu) = self.gpu.as_mut() else { return };
            let w = self.windows.get_mut(id).unwrap();
            if fresh {
                w.picture.canvas = Some(Canvas::new(generation, serial, size, scale, alpha));
            }
            let mut canvas = w.picture.canvas.take().unwrap();
            let started = Instant::now();
            let uploaded = gpu.uploaded_bytes;
            let rendered = gpu.render(&mut canvas, &root, local.loc);
            let upload_bytes = gpu.uploaded_bytes - uploaded;
            self.stats.render_us += started.elapsed().as_micros() as u64;
            self.stats.renders += 1;
            self.stats.uploaded_bytes += upload_bytes;
            let canvas_serial = canvas.serial();
            let rendered = rendered.map(|r| match r {
                // An image on the computer is shown nowhere: it is free for the next frame.
                Rendered::Frame { index, damaged_px, .. } if canvas.remote_image(index).is_none() => {
                    canvas.release(index);
                    Rendered::Kept { damaged_px }
                }
                other => other,
            });
            w.picture.canvas = Some(canvas);
            match rendered {
                Ok(Rendered::NoRoom) => {}
                Ok(Rendered::Unchanged) => {
                    self.stats.unchanged_renders += 1;
                    w.picture.dirty = false;
                }
                Ok(Rendered::Kept { damaged_px }) => {
                    w.picture.dirty = false;
                    self.stats.damaged_px += damaged_px;
                }
                Ok(Rendered::Frame { index, sync, damaged_px }) => {
                    w.picture.dirty = false;
                    self.stats.damaged_px += damaged_px;
                    let commit_us = w.picture.commit_us;
                    self.present_own(id, canvas_serial, index, sync, commit_us, upload_bytes);
                }
                Err(e) => {
                    tracing::warn!("window {id}: render failed: {e}");
                    w.picture.dirty = false;
                    failed = true;
                }
            }
        }
        if failed {
            self.renderer_failed();
        }
    }

    /// A render failed. Its device may be lost (the phone abandons a GPU that stops
    /// responding, while its executor stays), and then every later render fails too: the
    /// renderer is made again, which draws every window again, at most once per
    /// `RECOVERY_INTERVAL`.
    fn renderer_failed(&mut self) {
        if self.gpu_recovery_pending {
            return;
        }
        let wait = self.gpu_recovered_at.map_or(Duration::ZERO, |at| RECOVERY_INTERVAL.saturating_sub(at.elapsed()));
        self.gpu_recovery_pending = true;
        let recover = |state: &mut State| {
            state.gpu_recovery_pending = false;
            state.gpu_recovered_at = Some(Instant::now());
            tracing::warn!("a render failed: making the renderer again");
            state.rebuild_gpu();
        };
        if self.handle.insert_source(Timer::from_duration(wait), move |_, _, state: &mut State| {
            recover(state);
            TimeoutAction::Drop
        }).is_err() {
            self.gpu_recovery_pending = false;
        }
    }

    /// Presents a rendered image once its GPU work has finished.
    fn present_own(&mut self, window: u64, canvas: u64, index: usize, sync: SyncPoint, commit_us: u64, bytes: u64) {
        let request = self.remote_presents.begin(window, Held::Own { canvas, index });
        if let Some(w) = self.windows.get_mut(window) {
            w.picture.finishing = Some((request, canvas, index));
        }
        if sync.is_reached() {
            self.finish_own(window, request, commit_us, bytes);
            return;
        }
        let inserted = match sync.export() {
            // The fence as a file: the loop wakes when it signals.
            Some(fd) => self
                .handle
                .insert_source(Generic::new(fd, Interest::READ, Mode::OneShot), move |_, _, state: &mut State| {
                    state.finish_own(window, request, commit_us, bytes);
                    Ok(PostAction::Remove)
                })
                .is_ok(),
            // Otherwise the fence is checked every millisecond; checking does not wait.
            None => {
                let since = Instant::now();
                self.handle
                    .insert_source(Timer::from_duration(FENCE_POLL), move |_, _, state: &mut State| {
                        if sync.is_reached() {
                            state.finish_own(window, request, commit_us, bytes);
                            return TimeoutAction::Drop;
                        }
                        if since.elapsed() > FENCE_LIMIT {
                            tracing::warn!("window {window}: a frame's GPU work did not finish; dropped");
                            state.own_present_released(request);
                            return TimeoutAction::Drop;
                        }
                        TimeoutAction::ToDuration(FENCE_POLL)
                    })
                    .is_ok()
            }
        };
        if !inserted {
            self.own_present_released(request);
        }
    }

    /// A rendered frame's GPU work finished: the broker is asked to show it, unless the
    /// window moved on (a new size, a new renderer) since.
    fn finish_own(&mut self, window: u64, request: u64, commit_us: u64, bytes: u64) {
        let now = self.now_us();
        let Some(w) = self.windows.get_mut(window) else {
            self.remote_presents.released(request);
            return;
        };
        let Some((_, canvas, index)) = w.picture.finishing.filter(|(r, _, _)| *r == request) else {
            self.own_present_released(request);
            return;
        };
        w.picture.finishing = None;
        let image = w.picture.canvas.as_ref().filter(|c| c.serial() == canvas).and_then(|c| c.remote_image(index));
        let Some(image) = image else {
            self.own_present_released(request);
            return;
        };
        let size = smithay::backend::allocator::Buffer::size(image);
        let identity = crate::remote_buffers::identity(image);
        let (Some(identity), Ok(width), Ok(height)) = (identity, u32::try_from(size.w), u32::try_from(size.h)) else {
            self.own_present_released(request);
            return;
        };
        w.picture.trace.presents.push(crate::frame_trace::Present { at_us: now, commit_us, bytes });
        self.stats.presents += 1;
        self.send_remote_present(request, window, identity, width, height);
    }

    /// Whether the window's tree holds a phone-resident buffer covering its geometry: its
    /// root's, or a subsurface's over the whole window.
    pub(crate) fn covered_by_remote_buffer(&self, id: u64) -> bool {
        use smithay::backend::renderer::utils::RendererSurfaceStateUserData;
        use smithay::wayland::compositor::{with_surface_tree_downward, TraversalAction};
        let Some(w) = self.windows.get(id) else { return false };
        let Some(root) = w.surface.wl_surface() else { return false };
        let mut remote = Vec::new();
        with_surface_tree_downward(
            &root,
            (),
            |_, _, _| TraversalAction::DoChildren(()),
            |surface, states, _| {
                // The walk holds each surface's state: read it from there.
                let is_remote = states
                    .data_map
                    .get::<RendererSurfaceStateUserData>()
                    .and_then(|d| d.lock().unwrap().buffer().cloned())
                    .and_then(|b| smithay::wayland::dmabuf::get_dmabuf(&b).ok().map(crate::remote_buffers::is_remote))
                    .unwrap_or(false);
                if is_remote {
                    remote.push(surface.clone());
                }
            },
            |_, _, _| true,
        );
        let geometry = w.local_geometry();
        remote.iter().any(|s| *s == root || crate::state::covers_geometry(s, geometry))
    }

    /// The broker is done with a present of the compositor's own image (or it was never
    /// sent): the image is free for the next frame.
    pub(crate) fn own_present_released(&mut self, request: u64) {
        if let Some((window, held)) = self.remote_presents.released(request) {
            self.free_held(window, held);
        }
    }

    /// Returns a released hold: a client's buffer goes back to the client (dropped), an
    /// image of the window's current canvas becomes free.
    pub(crate) fn free_held(&mut self, window: u64, held: Held) {
        let Held::Own { canvas, index } = held else { return };
        let Some(w) = self.windows.get_mut(window) else { return };
        if w.picture.finishing.is_some_and(|(_, c, i)| c == canvas && i == index) {
            w.picture.finishing = None;
        }
        if let Some(c) = w.picture.canvas.as_mut().filter(|c| c.serial() == canvas) {
            c.release(index);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pictures_keep_their_buffers_density() {
        // A scale-1 X11 dialog on a 3x display is drawn at its own pixels.
        assert_eq!(picture_scale(1.0, 3.0), 1.0);
        // A buffer at the display's density, or a fractional one, keeps it.
        assert_eq!(picture_scale(3.0, 3.0), 3.0);
        assert_eq!(picture_scale(2.5, 3.0), 2.5);
        // Never above the display's density, never below one.
        assert_eq!(picture_scale(4.0, 3.0), 3.0);
        assert_eq!(picture_scale(0.5, 2.0), 1.0);
    }

    #[test]
    fn odd_sized_windows_keep_their_exact_size() {
        assert_eq!(picture_size(300, 161, 1.0), (300, 161));
        assert_eq!(picture_size(301, 161, 1.5), (452, 242));
        assert_eq!(picture_size(0, 0, 2.0), (1, 1));
    }
}

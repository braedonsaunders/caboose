//! A window's picture: the bookkeeping around the GPU images the compositor renders a
//! window into (render.rs) and presents in it (docs/gpu-buffers.md).
//!
//! The rules:
//! - a window is rendered only after it committed something (`dirty`), and a render with
//!   no damage presents nothing;
//! - each window has at most [`IMAGES`] images. One is rendered while another is with the
//!   broker (shown, or waiting to be), so the compositor never waits on the phone to draw
//!   a frame. With every image held, the window stays dirty and its frame callbacks wait
//!   for the broker to release one: the application slows to what the phone shows;
//! - an image's age, for the damage tracker, is how many frames ago it was last rendered.
//!
//! Nothing here touches the GPU; the pool is generic over the image it holds.

/// Images per window: one being rendered, one shown or queued.
pub const IMAGES: usize = 2;

/// A window's images, each free or held from its render until the broker releases it.
#[derive(Debug)]
pub struct Pool<B> {
    slots: Vec<Slot<B>>,
    /// Frames rendered into this pool so far.
    frame: u64,
}

#[derive(Debug)]
struct Slot<B> {
    image: B,
    held: bool,
    /// The frame this image was last rendered as, if any.
    rendered: Option<u64>,
}

impl<B> Default for Pool<B> {
    fn default() -> Self {
        Self { slots: Vec::new(), frame: 0 }
    }
}

impl<B> Pool<B> {
    /// A free image to render the next frame into, and its age (0 for a new image or one
    /// whose content is unknown, which is redrawn whole). Allocates with `make` while the
    /// pool has fewer than [`IMAGES`]; `None` when every image is held.
    pub fn acquire<E>(&mut self, make: impl FnOnce() -> Result<B, E>) -> Result<Option<(usize, usize)>, E> {
        let free = self
            .slots
            .iter()
            .enumerate()
            .filter(|(_, slot)| !slot.held)
            // The most recently rendered free image needs the least redrawn.
            .max_by_key(|(_, slot)| slot.rendered.map_or(0, |f| f + 1))
            .map(|(index, _)| index);
        let index = match free {
            Some(index) => index,
            None if self.slots.len() < IMAGES => {
                self.slots.push(Slot { image: make()?, held: false, rendered: None });
                self.slots.len() - 1
            }
            None => return Ok(None),
        };
        // The next frame is `frame + 1`; an image rendered as frame f is that many behind.
        let age = self.slots[index].rendered.map_or(0, |f| (self.frame + 1 - f) as usize);
        Ok(Some((index, age)))
    }

    pub fn image_mut(&mut self, index: usize) -> &mut B {
        &mut self.slots[index].image
    }

    pub fn image(&self, index: usize) -> &B {
        &self.slots[index].image
    }

    /// The image was rendered as the next frame and is held until [`Pool::release`].
    pub fn rendered(&mut self, index: usize) {
        self.frame += 1;
        let slot = &mut self.slots[index];
        slot.rendered = Some(self.frame);
        slot.held = true;
    }

    /// A render that changed nothing: the image is free again and keeps its age.
    pub fn unchanged(&mut self, index: usize) {
        self.slots[index].held = false;
    }

    /// The image's content is unknown (a failed render): it is redrawn whole next time.
    pub fn forget(&mut self, index: usize) {
        let slot = &mut self.slots[index];
        slot.held = false;
        slot.rendered = None;
    }

    /// The broker released the image.
    pub fn release(&mut self, index: usize) {
        if let Some(slot) = self.slots.get_mut(index) {
            slot.held = false;
        }
    }

    /// Whether a frame could be rendered now.
    pub fn has_room(&self) -> bool {
        self.slots.len() < IMAGES || self.slots.iter().any(|slot| !slot.held)
    }
}

/// Where a window's current content is shown from.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    /// The compositor renders the window's surface tree into its own images.
    #[default]
    Composed,
    /// The window's tree is one phone-resident buffer covering it, presented as it is.
    Direct,
}

/// A window's picture state, apart from its GPU images (render.rs `Canvas`).
#[derive(Debug, Default)]
pub struct Picture {
    /// Committed since its last render.
    pub dirty: bool,
    /// Frame callbacks are waiting to be released.
    pub callbacks_pending: bool,
    /// When the newest commit arrived (CLOCK_MONOTONIC µs).
    pub commit_us: u64,
    pub source: Source,
    /// The images' renderer generation, size and format; a change starts a new pool.
    pub canvas: Option<crate::render::Canvas>,
    /// A rendered image waiting for its GPU work to finish before it is presented:
    /// (present request, canvas serial, image index).
    pub finishing: Option<(u64, u64, usize)>,
    pub trace: crate::frame_trace::WindowTrace,
}

impl Picture {
    pub fn mark_dirty(&mut self, now_us: u64) {
        self.trace.commits.push(now_us);
        self.commit_us = now_us;
        self.dirty = true;
        self.callbacks_pending = true;
    }

    /// Whether the window's application may draw its next frame: the compositor has an
    /// image to render it into, or does not render the window at all.
    pub fn can_release_callbacks(&self) -> bool {
        self.source == Source::Direct || self.canvas.as_ref().is_none_or(|c| c.has_room())
    }

    /// Everything is drawn again: the images and their history go.
    pub fn repaint(&mut self) {
        self.canvas = None;
        self.finishing = None;
        self.dirty = true;
    }
}

/// Whether a buffer-window bind may name `window`: it exists and has a present the broker
/// has not released. Toplevels, popups and X11 windows alike; the bound process may be any
/// live process of the compositor's user, the compositor itself included.
pub fn buffer_bind_admits(window_exists: bool, presenting: bool, process_ours: bool) -> bool {
    window_exists && presenting && process_ours
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make(n: &mut u32) -> impl FnMut() -> Result<u32, ()> + '_ {
        move || {
            *n += 1;
            Ok(*n)
        }
    }

    #[test]
    fn the_pool_grows_to_two_images_and_then_waits_for_a_release() {
        let mut made = 0;
        let mut pool = Pool::default();
        let (a, age) = pool.acquire(make(&mut made)).unwrap().unwrap();
        assert_eq!((a, age), (0, 0));
        pool.rendered(a);
        let (b, age) = pool.acquire(make(&mut made)).unwrap().unwrap();
        assert_eq!((b, age), (1, 0));
        pool.rendered(b);
        assert!(!pool.has_room());
        assert_eq!(pool.acquire(make(&mut made)).unwrap(), None);
        assert_eq!(made, 2, "no more than two images");
        pool.release(a);
        assert!(pool.has_room());
        // Image 0 was rendered as frame 1; frame 3 is next: two frames of damage to redraw.
        assert_eq!(pool.acquire(make(&mut made)).unwrap(), Some((0, 2)));
    }

    #[test]
    fn steady_double_buffering_has_age_two() {
        let mut made = 0;
        let mut pool = Pool::default();
        for frame in 0..10 {
            let (index, age) = pool.acquire(make(&mut made)).unwrap().unwrap();
            assert_eq!(index, frame % 2);
            assert_eq!(age, if frame < 2 { 0 } else { 2 });
            pool.rendered(index);
            // The previous frame's image comes back once this one is shown.
            if frame > 0 {
                pool.release(1 - index);
            }
        }
    }

    #[test]
    fn an_unchanged_render_keeps_the_image_and_its_age() {
        let mut made = 0;
        let mut pool = Pool::default();
        let (a, _) = pool.acquire(make(&mut made)).unwrap().unwrap();
        pool.rendered(a);
        pool.release(a);
        let (again, age) = pool.acquire(make(&mut made)).unwrap().unwrap();
        assert_eq!((again, age), (a, 1), "the newest free image is reused before a new one is made");
        pool.unchanged(again);
        assert_eq!(pool.acquire(make(&mut made)).unwrap(), Some((a, 1)));
        pool.forget(a);
        assert_eq!(pool.acquire(make(&mut made)).unwrap(), Some((a, 0)), "a forgotten image is redrawn whole");
    }

    #[test]
    fn a_failed_allocation_leaves_the_pool_as_it_was() {
        let mut pool: Pool<u32> = Pool::default();
        assert_eq!(pool.acquire(|| Err("no memory")), Err("no memory"));
        assert!(pool.has_room());
        let mut made = 0;
        assert_eq!(pool.acquire(make(&mut made)).unwrap(), Some((0, 0)));
    }

    #[test]
    fn releases_of_unknown_images_are_ignored() {
        let mut pool: Pool<u32> = Pool::default();
        pool.release(5);
        assert!(pool.has_room());
    }

    #[test]
    fn buffer_binds_admit_any_window_kind_and_the_compositor_itself() {
        // The compositor's own process presenting a popup's or X11 window's image.
        assert!(buffer_bind_admits(true, true, true));
        // Nothing presented in the window, no such window, or another user's process.
        assert!(!buffer_bind_admits(true, false, true));
        assert!(!buffer_bind_admits(false, true, true));
        assert!(!buffer_bind_admits(true, true, false));
    }

    #[test]
    fn callbacks_wait_while_every_image_is_held() {
        let mut picture = Picture::default();
        assert!(picture.can_release_callbacks(), "nothing rendered yet");
        picture.source = Source::Direct;
        assert!(picture.can_release_callbacks());
    }
}

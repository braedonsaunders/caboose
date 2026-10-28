//! The client's displays as Wayland outputs.
//!
//! Each display the client announces becomes a `wl_output` with its pixel size, refresh
//! and scale, so applications render at the phone's or TV's density. Outputs are laid
//! side by side in the logical space (X11 applications see that layout as the root
//! window). Before any client connects there is one output from `--display`; after a
//! client leaves its displays stay, so windows keep their sizes for the next one.

use crate::state::State;
use caboose_display_protocol as proto;
use smithay::output::{Mode, Output, PhysicalProperties, Scale, Subpixel};
use smithay::reexports::wayland_server::backend::GlobalId;
use smithay::reexports::wayland_server::DisplayHandle;
use smithay::utils::{Logical, Point, Rectangle, Size, Transform};

pub struct DisplayOutput {
    pub info: proto::Display,
    pub output: Output,
    global: GlobalId,
    /// Origin in the logical space.
    pub origin: Point<i32, Logical>,
}

impl DisplayOutput {
    pub fn logical_size(&self) -> Size<i32, Logical> {
        (
            (self.info.width as f64 / self.info.scale).round() as i32,
            (self.info.height as f64 / self.info.scale).round() as i32,
        )
            .into()
    }

    pub fn logical_rect(&self) -> Rectangle<i32, Logical> {
        Rectangle::new(self.origin, self.logical_size())
    }

    /// Display pixels → logical, relative.
    pub fn to_logical(&self, px: f64) -> f64 {
        px / self.info.scale
    }

    pub fn to_pixels(&self, logical: f64) -> f64 {
        logical * self.info.scale
    }
}

#[derive(Default)]
pub struct Displays {
    list: Vec<DisplayOutput>,
}

/// What changed when the set was replaced.
pub struct Change {
    pub removed: Vec<u32>,
    pub changed: Vec<u32>,
}

fn mode(d: &proto::Display) -> Mode {
    Mode { size: (d.width, d.height).into(), refresh: (d.refresh_hz * 1000.0).round() as i32 }
}

impl Displays {
    pub fn iter(&self) -> impl Iterator<Item = &DisplayOutput> {
        self.list.iter()
    }

    pub fn get(&self, id: u32) -> Option<&DisplayOutput> {
        self.list.iter().find(|d| d.info.id == id)
    }

    /// The display a window without one goes to.
    pub fn primary(&self) -> &DisplayOutput {
        self.list.first().expect("there is always at least one display")
    }

    /// The display for an id, or the primary one.
    pub fn resolve(&self, id: Option<u32>) -> &DisplayOutput {
        id.and_then(|id| self.get(id)).unwrap_or_else(|| self.primary())
    }

    pub fn outputs(&self) -> impl Iterator<Item = &Output> {
        self.list.iter().map(|d| &d.output)
    }

    pub fn ids(&self) -> Vec<u32> {
        self.list.iter().map(|d| d.info.id).collect()
    }

    /// The display whose output this is.
    pub fn by_output(&self, output: &Output) -> Option<&DisplayOutput> {
        self.list.iter().find(|d| &d.output == output)
    }

    /// Replaces the set. Unchanged displays keep their output; an empty set is ignored
    /// (there must always be somewhere to put windows).
    pub fn replace(&mut self, dh: &DisplayHandle, displays: &[proto::Display]) -> Change {
        let mut change = Change { removed: Vec::new(), changed: Vec::new() };
        if displays.is_empty() {
            return change;
        }
        let mut old = std::mem::take(&mut self.list);
        let mut x = 0;
        for info in displays {
            if self.list.iter().any(|d| d.info.id == info.id) {
                continue; // a repeated id: the first wins
            }
            let reused = old.iter().position(|d| d.info.id == info.id).map(|i| old.remove(i));
            let origin: Point<i32, Logical> = (x, 0).into();
            let entry = match reused {
                Some(mut d) => {
                    if d.info != *info || d.origin != origin {
                        configure(&d.output, info, origin);
                        change.changed.push(info.id);
                    }
                    d.info = info.clone();
                    d.origin = origin;
                    d
                }
                None => {
                    let output = Output::new(
                        format!("caboose-{}", info.id),
                        PhysicalProperties {
                            size: (0, 0).into(),
                            subpixel: Subpixel::Unknown,
                            make: "Caboose".into(),
                            model: format!("Display {}", info.id),
                        },
                    );
                    configure(&output, info, origin);
                    let global = output.create_global::<State>(dh);
                    DisplayOutput { info: info.clone(), output, global, origin }
                }
            };
            x += entry.logical_size().w;
            self.list.push(entry);
        }
        for d in old {
            change.removed.push(d.info.id);
            dh.remove_global::<State>(d.global);
        }
        change
    }
}

fn configure(output: &Output, info: &proto::Display, origin: Point<i32, Logical>) {
    let m = mode(info);
    output.change_current_state(Some(m), Some(Transform::Normal), Some(Scale::Fractional(info.scale)), Some(origin));
    output.set_preferred(m);
}

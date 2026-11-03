//! Shared by the integration tests: the compositor as a process, a Wayland client, and a
//! Caboose Display client (a phone).

mod phone;
mod probe;
mod server;
mod xgrab;

pub use phone::Phone;
#[allow(unused_imports)]
pub use probe::{Probe, Toplevel};
pub use server::{docs_path, Server};
pub use xgrab::XGrabber;

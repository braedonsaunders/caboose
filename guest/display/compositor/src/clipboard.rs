//! The clipboard, between the phone, Wayland applications and X11 applications.
//!
//! Whoever copied last owns the selection:
//! - a Wayland client: its data source is the Wayland selection; X11 applications see it
//!   through Xwayland's window manager;
//! - an X11 application: the window manager announces it and the compositor offers it as
//!   its own Wayland selection ([`Owner::X11`]), reading from X11 on demand;
//! - the phone (`clipboard` from the client): the compositor holds what it copied and
//!   offers it to both ([`Owner::Phone`]).
//!
//! A copy carries text, an image (PNG or JPEG) and files (`text/uri-list`), in any
//! combination, within [`proto::clipboard::MAX_BYTES`] together. What applications copy
//! is read through pipes on short-lived threads, each bounded in size and time, and sent
//! to the phone in the types it asked for in its hello; what the phone copied is written
//! to readers the same way, so a slow application never blocks the compositor.

use crate::pipes;
use crate::state::State;
use caboose_display_protocol::clipboard::{self as types, JPEG, PNG, TEXT, URI_LIST};
use caboose_display_protocol::{self as proto, ClipboardEntry, Message};
use smithay::reexports::calloop::channel::Sender;
use smithay::wayland::selection::data_device::{request_data_device_client_selection, set_data_device_selection};
use smithay::wayland::selection::{SelectionSource, SelectionTarget};
use std::os::fd::OwnedFd;
use std::sync::Arc;
use std::time::Duration;

/// Text types offered for the phone's text and looked for in the computer's, best first.
pub const TEXT_MIMES: &[&str] = &[TEXT, "UTF8_STRING", "text/plain", "TEXT", "STRING"];
/// Image types looked for in the computer's copies, best first.
const IMAGE_MIMES: &[&str] = &[PNG, JPEG];
/// GNOME's and Thunar's list of copied files: `copy` or `cut`, then one URI per line.
const GNOME_FILES: &str = "x-special/gnome-copied-files";
/// How long an application has to hand over what it copied.
const READ_TIMEOUT: Duration = Duration::from_secs(5);
/// How long an application has to take what it pastes.
const WRITE_TIMEOUT: Duration = Duration::from_secs(30);
/// The most of an X11 copy read directly (not through Smithay), and for how long.
pub const X11_LIMIT: usize = types::MAX_BYTES;
pub const X11_TIMEOUT: Duration = Duration::from_secs(10);

/// Who provides a selection the compositor owns.
#[derive(Debug, Clone)]
pub enum Owner {
    X11,
    Phone(Arc<Offer>),
}

/// What the phone copied, as applications are offered it.
#[derive(Debug)]
pub struct Offer {
    /// Every type applications may ask for, with its bytes.
    types: Vec<(String, Arc<Vec<u8>>)>,
}

impl Offer {
    /// The offer for a copy that passed [`types::validate`].
    fn new(content: &proto::Clipboard) -> Self {
        let mut offered = Vec::new();
        for (mime, data) in content.entries() {
            let data = Arc::new(data.to_vec());
            match mime {
                TEXT => offered.extend(TEXT_MIMES.iter().map(|m| (m.to_string(), data.clone()))),
                URI_LIST => {
                    let mut gnome = b"copy".to_vec();
                    for line in data.split(|b| *b == b'\n') {
                        let line = line.strip_suffix(b"\r").unwrap_or(line);
                        if !line.is_empty() && !line.starts_with(b"#") {
                            gnome.push(b'\n');
                            gnome.extend_from_slice(line);
                        }
                    }
                    offered.push((URI_LIST.to_string(), data));
                    offered.push((GNOME_FILES.to_string(), Arc::new(gnome)));
                }
                other => offered.push((other.to_string(), data)),
            }
        }
        Self { types: offered }
    }

    pub fn mime_types(&self) -> Vec<String> {
        self.types.iter().map(|(m, _)| m.clone()).collect()
    }

    /// The bytes for a type an application asked for.
    pub fn data(&self, mime: &str) -> Option<Arc<Vec<u8>>> {
        self.types.iter().find(|(m, _)| m == mime).map(|(_, d)| d.clone())
    }

    /// Writes the bytes for `mime` to a reader's descriptor without blocking the loop;
    /// a type that is not offered closes the descriptor.
    pub fn send(&self, mime: &str, fd: OwnedFd) {
        if let Some(data) = self.data(mime) {
            std::thread::spawn(move || pipes::write_bounded(fd, &data, WRITE_TIMEOUT));
        }
    }
}

/// One representation of a copy to read from an application: the type it offers, the
/// protocol type it becomes, and the most it may take.
#[derive(Debug, Clone, PartialEq)]
struct Wanted {
    offered: String,
    mime: &'static str,
    limit: usize,
}

/// The representations worth reading from a copy offering `offered`: its best text, its
/// best image and its files, within the clipboard's limit together.
fn wanted(offered: &[String]) -> Vec<Wanted> {
    let has = |m: &str| offered.iter().any(|o| o == m);
    let mut wanted = Vec::new();
    if let Some(m) = TEXT_MIMES.iter().find(|m| has(m)) {
        wanted.push(Wanted { offered: m.to_string(), mime: TEXT, limit: types::MAX_TEXT_BYTES });
    }
    let files = if has(URI_LIST) { Some(URI_LIST) } else { has(GNOME_FILES).then_some(GNOME_FILES) };
    if let Some(m) = files {
        // GNOME's list has a `copy` or `cut` line before the URIs.
        wanted.push(Wanted { offered: m.to_string(), mime: URI_LIST, limit: types::MAX_URI_LIST_BYTES + 8 });
    }
    if let Some(m) = IMAGE_MIMES.iter().find(|m| has(m)) {
        let rest: usize = wanted.iter().map(|w| w.limit).sum();
        wanted.push(Wanted {
            offered: m.to_string(),
            mime: if *m == PNG { PNG } else { JPEG },
            limit: types::MAX_BYTES - rest,
        });
    }
    wanted
}

/// The protocol's bytes for what an application wrote: GNOME's list of files becomes a
/// `text/uri-list`.
fn normalize(offered: &str, data: Vec<u8>) -> Vec<u8> {
    if offered != GNOME_FILES {
        return data;
    }
    let mut out = Vec::new();
    for line in data.split(|b| *b == b'\n').skip(1) {
        if !line.is_empty() {
            out.extend_from_slice(line);
            out.extend_from_slice(b"\r\n");
        }
    }
    out
}

/// A copy from a set of representations read from an application: the valid ones, in
/// the protocol's order, or None if none is.
fn assemble(read: Vec<(&'static str, Vec<u8>)>) -> Option<proto::Clipboard> {
    let mut entries: Vec<ClipboardEntry> = types::TYPES
        .iter()
        .filter_map(|t| read.iter().find(|(m, _)| m == t))
        .filter(|(m, d)| types::matches(m, d).is_ok())
        .map(|(m, d)| ClipboardEntry { mime: m.to_string(), data: d.clone() })
        .collect();
    if entries.is_empty() {
        return None;
    }
    let first = entries.remove(0);
    let mut clip = proto::Clipboard { mime: first.mime, data: first.data, alternatives: entries };
    // Over the limit together (a file list grows a little as it is normalized): the
    // largest alternative goes first.
    while types::validate(&clip).is_err() && !clip.alternatives.is_empty() {
        let largest = (0..clip.alternatives.len()).max_by_key(|i| clip.alternatives[*i].data.len()).unwrap();
        clip.alternatives.remove(largest);
    }
    types::validate(&clip).is_ok().then_some(clip)
}

/// What a client is sent of a copy: the types it takes (text always), or None if that
/// leaves nothing.
pub fn for_client(content: &proto::Clipboard, takes: &[String]) -> Option<proto::Clipboard> {
    let mut entries: Vec<ClipboardEntry> = content
        .entries()
        .filter(|(m, _)| *m == TEXT || takes.iter().any(|t| t == m))
        .map(|(m, d)| ClipboardEntry { mime: m.to_owned(), data: d.to_vec() })
        .collect();
    if entries.is_empty() {
        return None;
    }
    let first = entries.remove(0);
    Some(proto::Clipboard { mime: first.mime, data: first.data, alternatives: entries })
}

/// A representation read from an application, for the copy numbered `serial`; None
/// when it could not be read in time or within its limit.
pub struct Read {
    serial: u64,
    mime: &'static str,
    data: Option<Vec<u8>>,
}

/// A copy being read.
struct Pending {
    serial: u64,
    expected: usize,
    read: Vec<(&'static str, Vec<u8>)>,
}

/// Clipboard state: the channel reads arrive on, the copy being read, and what the
/// phone last saw.
pub struct Clipboard {
    pub done: Sender<Read>,
    serial: u64,
    pending: Option<Pending>,
    /// The copy the phone has (sent to it, or copied on it).
    pub last_sent: Option<Arc<proto::Clipboard>>,
}

impl Clipboard {
    pub fn new(done: Sender<Read>) -> Self {
        Self { done, serial: 0, pending: None, last_sent: None }
    }

    /// Starts reading a new copy offering `offered`; returns what to read, each with
    /// where its bytes go. Reads of an older copy still in flight are ignored.
    fn begin(&mut self, offered: &[String]) -> Vec<(String, Sink)> {
        self.serial += 1;
        let wanted = wanted(offered);
        self.pending =
            (!wanted.is_empty()).then(|| Pending { serial: self.serial, expected: wanted.len(), read: Vec::new() });
        wanted
            .into_iter()
            .map(|w| (w.offered.clone(), Sink { serial: self.serial, wanted: w, done: self.done.clone() }))
            .collect()
    }
}

/// Where one representation's bytes go once an application has written them.
pub struct Sink {
    serial: u64,
    wanted: Wanted,
    done: Sender<Read>,
}

impl Sink {
    /// The most this representation may be.
    pub fn limit(&self) -> usize {
        self.wanted.limit
    }

    /// Reads from the pipe's read end on a thread.
    fn read_from(self, read: OwnedFd) {
        std::thread::spawn(move || {
            let data =
                pipes::read_bounded(read, self.wanted.limit, READ_TIMEOUT).map(|d| normalize(&self.wanted.offered, d));
            let _ = self.done.send(Read { serial: self.serial, mime: self.wanted.mime, data });
        });
    }

    fn failed(self) {
        let _ = self.done.send(Read { serial: self.serial, mime: self.wanted.mime, data: None });
    }
}

impl State {
    /// The phone copied: offer its text, image or files to Wayland and X11 applications.
    pub fn clipboard_from_phone(&mut self, c: proto::Clipboard) {
        if let Err(refusal) = types::validate(&c) {
            tracing::warn!("clipboard: refused the phone's copy: {refusal:?}");
            return;
        }
        // Files from the phone are the ones it uploaded to the transfer area, nothing else.
        if let Some((_, list)) = c.entries().find(|(m, _)| *m == URI_LIST) {
            let home = crate::transfers::home();
            let paths = types::file_paths(list).unwrap_or_default();
            if paths.iter().any(|p| crate::transfers::open(&home, p).is_none()) {
                tracing::warn!("clipboard: refused the phone's copy: a file is not in the transfer area");
                return;
            }
        }
        let offer = Arc::new(Offer::new(&c));
        self.clipboard.serial += 1;
        self.clipboard.pending = None;
        self.clipboard.last_sent = Some(Arc::new(c));
        let mimes = offer.mime_types();
        set_data_device_selection(&self.dh, &self.seat, mimes.clone(), Owner::Phone(offer));
        if let Some(xwm) = self.xwm.as_mut() {
            if let Err(e) = xwm.new_selection(SelectionTarget::Clipboard, Some(mimes)) {
                tracing::warn!("cannot offer the clipboard to X11: {e}");
            }
        }
    }

    /// A Wayland client copied: tell X11, and read the copy for the phone.
    pub fn clipboard_from_wayland(&mut self, ty: SelectionTarget, source: Option<SelectionSource>) {
        if let Some(xwm) = self.xwm.as_mut() {
            if let Err(e) = xwm.new_selection(ty, source.as_ref().map(|s| s.mime_types())) {
                tracing::warn!("cannot offer the selection to X11: {e}");
            }
        }
        if ty != SelectionTarget::Clipboard {
            return;
        }
        let offered = source.map(|s| s.mime_types()).unwrap_or_default();
        tracing::debug!("clipboard: a Wayland client copied {offered:?}");
        let reads = self.clipboard.begin(&offered);
        if reads.is_empty() {
            return;
        }
        // Smithay reports the new selection before it records it as the seat's; ask for
        // the data once the request has been handled.
        self.handle.insert_idle(move |state| {
            for (mime, sink) in reads {
                let Ok((read, write)) = pipes::pipe() else {
                    sink.failed();
                    continue;
                };
                match request_data_device_client_selection(&state.seat, mime, write) {
                    Ok(()) => sink.read_from(read),
                    Err(e) => {
                        tracing::debug!("clipboard: cannot read the new selection: {e}");
                        sink.failed();
                    }
                }
            }
        });
    }

    /// An X11 application copied: read the copy for the phone.
    pub fn clipboard_from_x11(&mut self, mime_types: &[String]) {
        let reads = self.clipboard.begin(mime_types);
        for (mime, sink) in reads {
            let Ok((read, write)) = pipes::pipe() else {
                sink.failed();
                continue;
            };
            if !crate::x11sel::smithay_transfers(&mime) {
                // Smithay's window manager cannot transfer this type; read it directly.
                match self.x11.clone() {
                    Some(access) => {
                        crate::x11sel::copy_into(access, mime, write, sink.limit(), READ_TIMEOUT);
                        sink.read_from(read);
                    }
                    None => sink.failed(),
                }
                continue;
            }
            let handle = self.handle.clone();
            match self.xwm.as_mut().map(|xwm| xwm.send_selection(SelectionTarget::Clipboard, mime, write, handle)) {
                Some(Ok(())) => sink.read_from(read),
                _ => sink.failed(),
            }
        }
    }

    /// One representation of a copy arrived from its application.
    pub fn clipboard_read(&mut self, read: Read) {
        let Some(pending) = self.clipboard.pending.as_mut().filter(|p| p.serial == read.serial) else { return };
        pending.expected -= 1;
        if let Some(data) = read.data {
            tracing::debug!("clipboard: read {} bytes of {} from the computer", data.len(), read.mime);
            pending.read.push((read.mime, data));
        }
        if pending.expected > 0 {
            return;
        }
        let pending = self.clipboard.pending.take().unwrap();
        let Some(content) = assemble(pending.read) else { return };
        // The phone's own copy coming back through an application is not news.
        if self.clipboard.last_sent.as_deref() == Some(&content) {
            return;
        }
        let content = Arc::new(content);
        self.clipboard.last_sent = Some(content.clone());
        self.send_clipboard(&content);
    }

    /// Sends a copy to the connected client, in the types it takes.
    pub fn send_clipboard(&mut self, content: &proto::Clipboard) {
        let Some((conn, clip)) = self
            .session
            .as_ref()
            .filter(|s| s.ready)
            .and_then(|s| for_client(content, &s.clipboard_types).map(|clip| (s.conn, clip)))
        else {
            return;
        };
        self.net.send(conn, &Message::ServerClipboard(clip));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn offered(m: &[&str]) -> Vec<String> {
        m.iter().map(|s| s.to_string()).collect()
    }

    const PNG_BYTES: &[u8] = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR";

    #[test]
    fn the_best_text_image_and_files_are_read() {
        let w = wanted(&offered(&["STRING", TEXT, "image/bmp", JPEG, PNG, GNOME_FILES]));
        let pairs: Vec<_> = w.iter().map(|w| (w.offered.as_str(), w.mime)).collect();
        assert_eq!(pairs, vec![(TEXT, TEXT), (GNOME_FILES, URI_LIST), (PNG, PNG)]);
        assert!(w.iter().map(|w| w.limit).sum::<usize>() <= types::MAX_BYTES);
        let w = wanted(&offered(&["TARGETS", "UTF8_STRING", URI_LIST, GNOME_FILES]));
        let pairs: Vec<_> = w.iter().map(|w| (w.offered.as_str(), w.mime)).collect();
        assert_eq!(pairs, vec![("UTF8_STRING", TEXT), (URI_LIST, URI_LIST)]);
        assert!(wanted(&offered(&["text/html", "image/bmp"])).is_empty());
    }

    #[test]
    fn gnome_file_lists_become_uri_lists() {
        let data = normalize(GNOME_FILES, b"copy\nfile:///home/caboose/a\nfile:///home/caboose/b".to_vec());
        assert_eq!(data, b"file:///home/caboose/a\r\nfile:///home/caboose/b\r\n");
        assert_eq!(normalize(URI_LIST, b"file:///x\r\n".to_vec()), b"file:///x\r\n");
    }

    #[test]
    fn a_copy_keeps_its_valid_representations_in_order() {
        let clip = assemble(vec![(PNG, PNG_BYTES.to_vec()), (TEXT, b"hi".to_vec())]).unwrap();
        assert_eq!(clip.mime, TEXT);
        assert_eq!(clip.alternatives.iter().map(|e| e.mime.as_str()).collect::<Vec<_>>(), vec![PNG]);
        // An image without its signature is left out; the text stays.
        let clip = assemble(vec![(PNG, b"not a png".to_vec()), (TEXT, b"hi".to_vec())]).unwrap();
        assert!(clip.alternatives.is_empty());
        assert!(assemble(vec![(PNG, b"not a png".to_vec())]).is_none());
    }

    #[test]
    fn a_client_gets_only_the_types_it_takes() {
        let clip = assemble(vec![
            (TEXT, b"a.png".to_vec()),
            (PNG, PNG_BYTES.to_vec()),
            (URI_LIST, b"file:///home/caboose/a.png\r\n".to_vec()),
        ])
        .unwrap();
        let text_only = for_client(&clip, &[]).unwrap();
        assert_eq!((text_only.mime.as_str(), text_only.alternatives.len()), (TEXT, 0));
        let images = for_client(&clip, &offered(&[PNG])).unwrap();
        assert_eq!(images.alternatives.iter().map(|e| e.mime.as_str()).collect::<Vec<_>>(), vec![PNG]);
        let image_only = assemble(vec![(PNG, PNG_BYTES.to_vec())]).unwrap();
        assert!(for_client(&image_only, &[]).is_none());
        assert_eq!(for_client(&image_only, &offered(&[PNG])).unwrap().mime, PNG);
    }

    #[test]
    fn the_phones_copy_is_offered_in_every_type_applications_ask_for() {
        let clip = proto::Clipboard {
            mime: TEXT.into(),
            data: b"hi".to_vec(),
            alternatives: vec![ClipboardEntry {
                mime: URI_LIST.into(),
                data: b"file:///h/a\r\nfile:///h/b\r\n".to_vec(),
            }],
        };
        let offer = Offer::new(&clip);
        let mimes = offer.mime_types();
        for m in TEXT_MIMES.iter().chain([&URI_LIST, &GNOME_FILES]) {
            assert!(mimes.iter().any(|o| o == m), "{m}");
        }
        assert_eq!(offer.data("UTF8_STRING").unwrap().as_slice(), b"hi");
        assert_eq!(offer.data(GNOME_FILES).unwrap().as_slice(), b"copy\nfile:///h/a\nfile:///h/b");
        assert!(offer.data(PNG).is_none());
    }
}

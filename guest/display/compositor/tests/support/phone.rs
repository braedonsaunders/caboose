use super::Server;
use caboose_display_protocol as proto;
use proto::{Decoded, Message, StreamDecoder};
use std::collections::{BTreeMap, VecDeque};
use std::net::TcpStream;
use std::time::{Duration, Instant};
use tungstenite::stream::MaybeTlsStream;
use tungstenite::{Message as Ws, WebSocket};

const WAIT: Duration = Duration::from_secs(15);

/// What a phone announces in its hello.
#[derive(Clone, Copy)]
pub struct Flags {
    wasm: bool,
    webview: bool,
    devices: bool,
    targets: bool,
    children: bool,
    audio: bool,
}

/// A Caboose Display client: connects, says hello, and reads the window messages.
pub struct Phone {
    ws: WebSocket<MaybeTlsStream<TcpStream>>,
    decoder: StreamDecoder,
    inbox: VecDeque<Message>,
    windows: BTreeMap<u64, proto::WindowCreate>,
    pub features: Vec<String>,
}

impl Phone {
    pub fn all() -> Flags {
        Flags { wasm: true, webview: true, devices: true, targets: true, children: true, audio: true }
    }

    pub fn bare() -> Flags {
        Flags { wasm: false, webview: false, devices: false, targets: false, children: false, audio: false }
    }

    pub fn connect(server: &Server, flags: Flags) -> Phone {
        let url = format!("ws://127.0.0.1:{}/", server.port);
        let mut request = tungstenite::client::IntoClientRequest::into_client_request(url.as_str()).unwrap();
        request.headers_mut().insert("sec-websocket-protocol", "binary".parse().unwrap());
        let (ws, _) = tungstenite::connect(request).expect("connect to the display");
        let tungstenite::stream::MaybeTlsStream::Plain(stream) = ws.get_ref() else { unreachable!() };
        stream.set_read_timeout(Some(Duration::from_millis(50))).unwrap();
        let mut phone = Phone {
            ws,
            decoder: StreamDecoder::new(),
            inbox: VecDeque::new(),
            windows: BTreeMap::new(),
            features: Vec::new(),
        };
        phone.send(Message::ClientHello(proto::ClientHello {
            version: proto::VERSION,
            token: String::new(),
            displays: vec![proto::Display { id: 1, width: 1280, height: 800, scale: 1.0, refresh_hz: 60.0, hdr: false }],
            audio_decoders: flags.audio.then(|| vec!["opus".to_owned()]),
            wasm: flags.wasm,
            webview: flags.webview,
            devices: flags.devices,
            targets: flags.targets,
            children: flags.children,
            clipboard_types: Some(vec!["image/png".into()]),
        }));
        let hello = phone
            .wait(|m| matches!(m, Message::ServerHello(_)).then(|| m.clone()))
            .expect("the server answers a hello");
        let Message::ServerHello(hello) = hello else { unreachable!() };
        phone.features = hello.features;
        phone
    }

    /// Returns once the compositor has handled everything sent so far (it reads in order).
    pub fn sync(&mut self) {
        self.send(Message::Ping { t_us: 7 });
        self.wait(|m| matches!(m, Message::Pong { t_us: 7 }).then_some(())).expect("the compositor answers a ping");
    }

    pub fn send(&mut self, message: Message) {
        self.ws.send(Ws::Binary(proto::encode(&message).into())).expect("send");
    }

    /// Reads whatever has arrived into the inbox.
    fn pump(&mut self) {
        loop {
            match self.ws.read() {
                Ok(Ws::Binary(bytes)) => self.decoder.push(&bytes),
                Ok(_) => {}
                Err(tungstenite::Error::Io(e)) if matches!(e.kind(), std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut) => break,
                Err(_) => break,
            }
        }
        while let Ok(Some(decoded)) = self.decoder.next_message() {
            if let Decoded::Message(m) = decoded {
                match &m {
                    Message::WindowCreate(c) => {
                        self.windows.insert(c.id, c.clone());
                    }
                    Message::WindowDestroy { id } => {
                        self.windows.remove(id);
                    }
                    _ => {}
                }
                self.inbox.push_back(m);
            }
        }
    }

    /// The first message (from now on, in order) `pick` accepts, within a deadline.
    fn wait<T>(&mut self, mut pick: impl FnMut(&Message) -> Option<T>) -> Option<T> {
        self.wait_for(WAIT, &mut pick)
    }

    fn wait_for<T>(&mut self, within: Duration, pick: &mut impl FnMut(&Message) -> Option<T>) -> Option<T> {
        let deadline = Instant::now() + within;
        loop {
            while let Some(m) = self.inbox.pop_front() {
                if let Some(found) = pick(&m) {
                    return Some(found);
                }
            }
            if Instant::now() > deadline {
                return None;
            }
            self.pump();
        }
    }

    /// The id of the next announced window `accept` takes.
    pub fn wait_window(&mut self, accept: impl Fn(&proto::WindowCreate) -> bool) -> Option<u64> {
        self.wait(|m| match m {
            Message::WindowCreate(c) if accept(c) => Some(c.id),
            _ => None,
        })
    }

    pub fn created(&self, id: u64) -> Option<proto::WindowCreate> {
        self.windows.get(&id).cloned()
    }

    /// The next `window.update` of `id` that `accept` takes.
    pub fn wait_hint(&mut self, id: u64, accept: impl Fn(&proto::WindowUpdate) -> bool) -> Option<()> {
        self.wait(|m| match m {
            Message::WindowUpdate(u) if u.id == id && accept(u) => Some(()),
            _ => None,
        })
    }

    pub fn wait_destroyed(&mut self, id: u64) -> Option<()> {
        self.wait(|m| matches!(m, Message::WindowDestroy { id: d } if *d == id).then_some(()))
    }

    pub fn wait_activate(&mut self, id: u64) -> Option<()> {
        self.wait(|m| matches!(m, Message::WindowActivate { id: a } if *a == id).then_some(()))
    }

    /// True when no `window.activate` arrives within `within`.
    pub fn no_activate_within(&mut self, within: Duration) -> bool {
        self.wait_for(within, &mut |m| matches!(m, Message::WindowActivate { .. }).then_some(())).is_none()
    }

    /// A vsync from the phone's display 1 releases a waiting application's frame callback.
    pub fn vsync_releases_frame_callbacks(&mut self, server: &Server) -> bool {
        let mut probe = super::Probe::connect(server);
        let Ok(window) = probe.toplevel() else { return false };
        probe.request_frame(&window);
        probe.roundtrip().ok();
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut t = 0u64;
        while Instant::now() < deadline {
            t += 16_000;
            self.send(Message::Vsync { display: 1, t_us: t });
            std::thread::sleep(Duration::from_millis(16));
            if probe.dispatch_pending().is_err() {
                return false;
            }
            if probe.frame_done() {
                return true;
            }
        }
        false
    }
}

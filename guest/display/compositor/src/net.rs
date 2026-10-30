//! The WebSocket listener the host relays to (`0.0.0.0:14600`), driven by the
//! compositor's event loop. Sockets are non-blocking; tungstenite buffers what the
//! kernel will not take yet and the edge-triggered source flushes it when the socket
//! drains. Protocol messages are parsed from the byte stream regardless of WebSocket
//! message boundaries.

use caboose_display_protocol::{self as proto, Decoded, StreamDecoder};
use smithay::reexports::calloop::{channel::{channel, Event as ChannelEvent}, generic::Generic, Interest, LoopHandle, Mode, PostAction, RegistrationToken};
use std::collections::HashMap;
use std::io;
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::time::Instant;
use tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tungstenite::handshake::{HandshakeError, MidHandshake};
use tungstenite::protocol::WebSocketConfig;
use tungstenite::{Bytes, Message as WsMessage, ServerHandshake, WebSocket};

pub type ConnId = u64;

/// What the network tells the compositor.
pub enum NetEvent {
    Message(ConnId, proto::Message),
    /// The peer sent something the protocol cannot accept; the connection is closed.
    ProtocolError(ConnId, String),
    Closed(ConnId),
}

struct SubprotocolCallback;

impl tungstenite::handshake::server::Callback for SubprotocolCallback {
    fn on_request(self, request: &Request, mut response: Response) -> Result<Response, ErrorResponse> {
        // Live GPU does not use the display codec. Until the private broker is
        // connected, reject its path rather than upgrading it as a display.
        if request.uri().path() == "/gpu" {
            let mut error = ErrorResponse::new(Some("GPU broker unavailable".into()));
            *error.status_mut() = tungstenite::http::StatusCode::SERVICE_UNAVAILABLE;
            return Err(error);
        }
        // The host relay asks for "binary"; echo it so the handshake completes.
        let offered = request
            .headers()
            .get_all("sec-websocket-protocol")
            .iter()
            .filter_map(|v| v.to_str().ok())
            .flat_map(|v| v.split(','))
            .any(|p| p.trim() == "binary");
        if offered {
            response.headers_mut().insert("sec-websocket-protocol", "binary".parse().unwrap());
        }
        Ok(response)
    }
}

type Handshake = MidHandshake<ServerHandshake<TcpStream, SubprotocolCallback>>;

enum Socket {
    Handshaking(Handshake),
    Open(WebSocket<TcpStream>),
    Gone,
}

struct Conn {
    socket: Socket,
    decoder: StreamDecoder,
    token: Option<RegistrationToken>,
    opened: Instant,
    /// When the peer last sent anything.
    heard: Instant,
    /// Set once the connection was asked to close; a peer that never finishes the
    /// close handshake is dropped by [`Net::stale_closing`].
    closing: Option<Instant>,
}

pub struct Net {
    conns: HashMap<ConnId, Conn>,
    next_id: ConnId,
    pub local: SocketAddr,
    gpu_router: Option<crate::gpu_supervisor::GpuRouter>,
}

fn config() -> WebSocketConfig {
    let mut c = WebSocketConfig::default();
    c.max_message_size = Some(proto::MAX_PAYLOAD + proto::HEADER_LEN);
    c.max_frame_size = Some(proto::MAX_PAYLOAD + proto::HEADER_LEN);
    // A peer that stops reading must not grow the server without bound: past a few
    // of the largest messages waiting, the connection is closed.
    c.max_write_buffer_size = 3 * (proto::MAX_PAYLOAD + proto::HEADER_LEN);
    c
}

/// Something with a `net` the loop callbacks can reach.
pub trait HasNet: Sized + 'static {
    fn net(&mut self) -> &mut Net;
    fn loop_handle(&self) -> LoopHandle<'static, Self>;
    fn on_net_events(&mut self, events: Vec<NetEvent>);
    fn on_gpu_record(&mut self, record: crate::gpu_control::Record);
    fn on_gpu_control_sent(&mut self, grant: Option<crate::gpu_grant::Grant>);
    fn on_gpu_control_failure(&mut self);
}

impl Net {
    /// Binds the listener and registers it with the loop.
    pub fn listen<S: HasNet>(addr: SocketAddr, handle: &LoopHandle<'static, S>) -> io::Result<Self> {
        let listener = TcpListener::bind(addr)?;
        listener.set_nonblocking(true)?;
        let local = listener.local_addr()?;
        handle
            .insert_source(Generic::new(listener, Interest::READ, Mode::Level), |_, listener, state: &mut S| {
                loop {
                    match listener.accept() {
                        Ok((stream, peer)) => state_accept(state, stream, peer),
                        Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                        Err(e) => {
                            tracing::warn!("accept failed: {e}");
                            break;
                        }
                    }
                }
                Ok(PostAction::Continue)
            })
            .map_err(|e| io::Error::other(e.to_string()))?;
        Ok(Self { conns: HashMap::new(), next_id: 1, local, gpu_router: None })
    }

    pub fn gpu_enabled(&self) -> bool { self.gpu_router.is_some() }

    /// Install only for the authenticated owner seat after the private broker
    /// has been installed and its complete bridge has passed integration.
    /// Until a caller explicitly invokes this, /gpu remains unavailable.
    #[allow(dead_code)]
    pub fn enable_private_gpu<S: HasNet>(
        &mut self,
        token_file: &std::path::Path,
        local_socket: &std::path::Path,
        handle: &LoopHandle<'static, S>,
    ) -> io::Result<()> {
        if self.gpu_router.is_some() {
            return Err(io::Error::new(io::ErrorKind::AlreadyExists, "GPU router already active"));
        }
        let (tx, rx) = channel::<crate::gpu_supervisor::RouteEvent>();
        let mut router = crate::gpu_supervisor::GpuRouter::start(token_file, local_socket, move |event| {
            let _ = tx.send(event);
        })?;
        let control = router.clone_control()?;
        handle.insert_source(rx, |event, _, state: &mut S| {
            if let ChannelEvent::Msg(event) = event {
                match event {
                    crate::gpu_supervisor::RouteEvent::Display(routed) => {
                        let (stream, peer) = routed.into_parts();
                        state_accept_display(state, stream, peer);
                    }
                    crate::gpu_supervisor::RouteEvent::ControlSent(grant) => state.on_gpu_control_sent(grant),
                    crate::gpu_supervisor::RouteEvent::ControlFailed => state.on_gpu_control_failure(),
                }
            }
        }).map_err(|e| io::Error::other(e.to_string()))?;
        handle.insert_source(Generic::new(control, Interest::READ, Mode::Level), |_, socket, state: &mut S| {
            loop {
                match crate::gpu_control::receive(socket) {
                    Ok(record) => state.on_gpu_record(record),
                    Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                    Err(_) => { state.on_gpu_control_failure(); return Ok(PostAction::Remove); }
                }
            }
            Ok(PostAction::Continue)
        }).map_err(|e| io::Error::other(e.to_string()))?;
        self.gpu_router = Some(router);
        Ok(())
    }

    pub fn fail_gpu_control(&mut self) {
        if let Some(router) = self.gpu_router.as_mut() { router.fail(); }
    }

    pub fn queue_gpu_control(&self, bytes: Vec<u8>, revoke: Option<crate::gpu_grant::Grant>) -> io::Result<()> {
        self.gpu_router.as_ref().ok_or_else(|| io::Error::other("GPU router unavailable"))?.queue_control(bytes, revoke)
    }

    /// Queues one protocol message. Errors other than a full kernel buffer close the
    /// connection at the next service.
    pub fn send(&mut self, id: ConnId, message: &proto::Message) {
        let bytes = proto::encode(message);
        self.send_bytes(id, bytes);
    }

    pub fn send_bytes(&mut self, id: ConnId, bytes: Vec<u8>) {
        let Some(conn) = self.conns.get_mut(&id) else { return };
        let Socket::Open(ws) = &mut conn.socket else { return };
        if conn.closing.is_some() {
            return;
        }
        let mut result = ws.write(WsMessage::Binary(Bytes::from(bytes)));
        if result.is_ok() {
            result = ws.flush();
        }
        match result {
            Ok(()) => {}
            Err(tungstenite::Error::Io(e)) if e.kind() == io::ErrorKind::WouldBlock => {}
            Err(e) => {
                tracing::info!("connection {id}: write failed: {e}");
                conn.closing.get_or_insert_with(Instant::now);
            }
        }
    }

    /// Sends a final message and closes the connection.
    pub fn close_with(&mut self, id: ConnId, message: Option<&proto::Message>) {
        if let Some(m) = message {
            self.send(id, m);
        }
        if let Some(conn) = self.conns.get_mut(&id) {
            if let Socket::Open(ws) = &mut conn.socket {
                let _ = ws.close(None);
                let _ = ws.flush();
            }
            conn.closing.get_or_insert_with(Instant::now);
        }
    }

    pub fn age(&self, id: ConnId) -> Option<std::time::Duration> {
        self.conns.get(&id).map(|c| c.opened.elapsed())
    }

    /// How long since the peer last sent anything.
    pub fn silent_for(&self, id: ConnId) -> Option<std::time::Duration> {
        self.conns.get(&id).map(|c| c.heard.elapsed())
    }

    pub fn ids(&self) -> Vec<ConnId> {
        self.conns.keys().copied().collect()
    }

    /// Reads, decodes and flushes one connection. Returns its events, including
    /// `Closed` once (after which the connection is forgotten).
    fn service(&mut self, id: ConnId) -> (Vec<NetEvent>, Option<RegistrationToken>) {
        let mut events = Vec::new();
        let Some(conn) = self.conns.get_mut(&id) else { return (events, None) };
        let mut dead = false;
        if let Socket::Handshaking(_) = conn.socket {
            let Socket::Handshaking(mid) = std::mem::replace(&mut conn.socket, Socket::Gone) else { unreachable!() };
            match mid.handshake() {
                Ok(ws) => conn.socket = Socket::Open(ws),
                Err(HandshakeError::Interrupted(mid)) => conn.socket = Socket::Handshaking(mid),
                Err(HandshakeError::Failure(e)) => {
                    tracing::info!("connection {id}: WebSocket handshake failed: {e}");
                    dead = true;
                }
            }
        }
        if let Socket::Open(ws) = &mut conn.socket {
            loop {
                let read = ws.read();
                if read.is_ok() {
                    conn.heard = Instant::now();
                }
                match read {
                    Ok(WsMessage::Binary(bytes)) => {
                        conn.decoder.push(&bytes);
                        loop {
                            match conn.decoder.next_message() {
                                Ok(Some(Decoded::Message(m))) => {
                                    if proto::Direction::of(m.type_id()) != proto::Direction::ClientToServer {
                                        events.push(NetEvent::ProtocolError(
                                            id,
                                            format!("{} sent by a client", m.name()),
                                        ));
                                        conn.closing.get_or_insert_with(Instant::now);
                                        break;
                                    }
                                    events.push(NetEvent::Message(id, m))
                                }
                                Ok(Some(Decoded::Unknown { type_id, .. })) => {
                                    tracing::debug!("connection {id}: skipped unknown type 0x{type_id:02x}")
                                }
                                Ok(Some(Decoded::Invalid { type_id, error })) => {
                                    tracing::warn!("connection {id}: dropped invalid 0x{type_id:02x}: {error}")
                                }
                                Ok(None) => break,
                                Err(e) => {
                                    events.push(NetEvent::ProtocolError(id, e.to_string()));
                                    conn.closing.get_or_insert_with(Instant::now);
                                    break;
                                }
                            }
                        }
                    }
                    Ok(WsMessage::Text(_)) => {
                        events.push(NetEvent::ProtocolError(id, "text WebSocket message".into()));
                        conn.closing.get_or_insert_with(Instant::now);
                    }
                    Ok(_) => {} // ping/pong/close frames are handled by tungstenite
                    Err(tungstenite::Error::Io(e)) if e.kind() == io::ErrorKind::WouldBlock => break,
                    Err(tungstenite::Error::ConnectionClosed | tungstenite::Error::AlreadyClosed) => {
                        dead = true;
                        break;
                    }
                    Err(e) => {
                        tracing::info!("connection {id}: {e}");
                        dead = true;
                        break;
                    }
                }
                if conn.closing.is_some() {
                    let _ = ws.close(None);
                    break;
                }
            }
            match ws.flush() {
                Ok(()) => {}
                Err(tungstenite::Error::Io(e)) if e.kind() == io::ErrorKind::WouldBlock => {}
                Err(_) => dead = true,
            }
        }
        if dead || matches!(conn.socket, Socket::Gone) {
            let conn = self.conns.remove(&id).unwrap();
            events.push(NetEvent::Closed(id));
            return (events, conn.token);
        }
        (events, None)
    }

    /// Connections asked to close that have not finished within `grace`.
    pub fn stale_closing(&self, grace: std::time::Duration) -> Vec<ConnId> {
        self.conns.iter().filter(|(_, c)| c.closing.is_some_and(|t| t.elapsed() > grace)).map(|(id, _)| *id).collect()
    }

    /// Drops a connection immediately.
    pub fn drop_conn(&mut self, id: ConnId) -> Option<RegistrationToken> {
        self.conns.remove(&id).and_then(|c| c.token)
    }
}

fn state_accept<S: HasNet>(state: &mut S, stream: TcpStream, peer: SocketAddr) {
    if let Some(router) = state.net().gpu_router.as_mut() {
        if let Err(e) = router.accept(stream, peer) {
            tracing::warn!("{peer}: GPU router refused connection: {e}");
        }
        return;
    }
    state_accept_display(state, stream, peer);
}

fn state_accept_display<S: HasNet>(state: &mut S, stream: TcpStream, peer: SocketAddr) {
    if let Err(e) = stream.set_nonblocking(true).and_then(|_| stream.set_nodelay(true)) {
        tracing::warn!("{peer}: {e}");
        return;
    }
    let registration = match stream.try_clone() {
        Ok(s) => s,
        Err(e) => {
            tracing::warn!("{peer}: {e}");
            return;
        }
    };
    let net = state.net();
    let id = net.next_id;
    net.next_id += 1;
    let socket = match tungstenite::accept_hdr_with_config(stream, SubprotocolCallback, Some(config())) {
        Ok(ws) => Socket::Open(ws),
        Err(HandshakeError::Interrupted(mid)) => Socket::Handshaking(mid),
        Err(HandshakeError::Failure(e)) => {
            tracing::info!("{peer}: WebSocket handshake failed: {e}");
            return;
        }
    };
    net.conns.insert(
        id,
        Conn {
            socket,
            decoder: StreamDecoder::new(),
            token: None,
            opened: Instant::now(),
            heard: Instant::now(),
            closing: None,
        },
    );
    tracing::info!("connection {id} from {peer}");
    let token = state.loop_handle().insert_source(
        Generic::new(registration, Interest::BOTH, Mode::Edge),
        move |_, _, state: &mut S| {
            let (events, token) = state.net().service(id);
            if let Some(token) = token {
                state.loop_handle().remove(token);
            }
            state.on_net_events(events);
            Ok(PostAction::Continue)
        },
    );
    match token {
        Ok(token) => {
            if let Some(conn) = state.net().conns.get_mut(&id) {
                conn.token = Some(token);
            }
        }
        Err(e) => {
            tracing::warn!("{peer}: cannot watch the socket: {e}");
            state.net().conns.remove(&id);
        }
    }
}

#[cfg(test)]
mod gpu_route_tests {
    use super::*;
    use tungstenite::handshake::server::Callback;

    #[test]
    fn unavailable_gpu_route_never_upgrades_as_display() {
        let request = Request::builder().uri("/gpu").body(()).unwrap();
        let response = Response::builder().body(()).unwrap();
        let error = SubprotocolCallback.on_request(&request, response).unwrap_err();
        assert_eq!(error.status().as_u16(), 503);
    }

    #[test]
    fn other_paths_keep_display_subprotocol() {
        let request = Request::builder().uri("/display")
            .header("sec-websocket-protocol", "binary").body(()).unwrap();
        let response = Response::builder().body(()).unwrap();
        let response = SubprotocolCallback.on_request(&request, response).unwrap();
        assert_eq!(response.headers().get("sec-websocket-protocol").unwrap(), "binary");
    }
}

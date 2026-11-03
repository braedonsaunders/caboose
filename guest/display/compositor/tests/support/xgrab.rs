use super::Server;
use std::os::unix::net::UnixStream;
use std::sync::mpsc::{channel, Sender};
use std::time::Duration;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{
    ConnectionExt as _, CreateWindowAux, EventMask, GrabMode, GrabStatus, WindowClass,
};
use x11rb::rust_connection::{DefaultStream, RustConnection};

/// An X11 client with a mapped window that can grab and release the keyboard.
pub struct XGrabber {
    commands: Sender<bool>,
    done: std::sync::mpsc::Receiver<Result<(), String>>,
}

/// The cookie of the first MIT-MAGIC-COOKIE-1 record in an Xauthority file.
fn cookie(path: &str) -> Option<Vec<u8>> {
    let data = std::fs::read(path).ok()?;
    let mut at = 2; // family
    let take = |data: &[u8], at: &mut usize| -> Option<Vec<u8>> {
        let n = u16::from_be_bytes([*data.get(*at)?, *data.get(*at + 1)?]) as usize;
        let value = data.get(*at + 2..*at + 2 + n)?.to_vec();
        *at += 2 + n;
        Some(value)
    };
    take(&data, &mut at)?; // address
    take(&data, &mut at)?; // display number
    take(&data, &mut at)?; // name
    take(&data, &mut at)
}

impl XGrabber {
    pub fn start(server: &Server) -> XGrabber {
        let display = server.x_display.expect("an X display");
        let authority = server.env_value("XAUTHORITY").expect("XAUTHORITY in the environment file");
        let cookie = cookie(&authority).expect("an X authority cookie");
        let (commands, receive) = channel::<bool>();
        let (report, done) = channel();
        let (ready_tx, ready_rx) = channel();
        std::thread::spawn(move || {
            let result = (|| -> Result<(), String> {
                let stream = UnixStream::connect(format!("/tmp/.X11-unix/X{display}")).map_err(|e| e.to_string())?;
                let (stream, _) = DefaultStream::from_unix_stream(stream).map_err(|e| e.to_string())?;
                let conn = RustConnection::connect_to_stream_with_auth_info(
                    stream,
                    0,
                    b"MIT-MAGIC-COOKIE-1".to_vec(),
                    cookie,
                )
                .map_err(|e| e.to_string())?;
                let screen = &conn.setup().roots[0];
                let window = conn.generate_id().map_err(|e| e.to_string())?;
                conn.create_window(
                    0,
                    window,
                    screen.root,
                    0,
                    0,
                    240,
                    160,
                    0,
                    WindowClass::INPUT_OUTPUT,
                    0,
                    &CreateWindowAux::new().event_mask(EventMask::KEY_PRESS | EventMask::EXPOSURE),
                )
                .map_err(|e| e.to_string())?;
                conn.map_window(window).map_err(|e| e.to_string())?;
                conn.flush().map_err(|e| e.to_string())?;
                ready_tx.send(()).ok();
                while let Ok(grab) = receive.recv() {
                    if grab {
                        let reply = conn
                            .grab_keyboard(false, window, x11rb::CURRENT_TIME, GrabMode::ASYNC, GrabMode::ASYNC)
                            .map_err(|e| e.to_string())?
                            .reply()
                            .map_err(|e| e.to_string())?;
                        if reply.status != GrabStatus::SUCCESS {
                            report.send(Err(format!("XGrabKeyboard: {:?}", reply.status))).ok();
                            continue;
                        }
                    } else {
                        conn.ungrab_keyboard(x11rb::CURRENT_TIME).map_err(|e| e.to_string())?;
                    }
                    conn.flush().map_err(|e| e.to_string())?;
                    report.send(Ok(())).ok();
                }
                Ok(())
            })();
            if let Err(e) = result {
                report.send(Err(e)).ok();
            }
        });
        ready_rx.recv_timeout(Duration::from_secs(10)).expect("the X11 client connected");
        XGrabber { commands, done }
    }

    fn send(&self, grab: bool) {
        self.commands.send(grab).unwrap();
        self.done.recv_timeout(Duration::from_secs(10)).expect("the X11 client answered").expect("X11 request");
    }

    pub fn grab(&self) {
        self.send(true);
    }

    pub fn release(&self) {
        self.send(false);
    }
}

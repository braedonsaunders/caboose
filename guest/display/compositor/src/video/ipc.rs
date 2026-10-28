//! The Caboose video socket: the VA-API passthrough driver (guest/vaapi) talks to the
//! compositor over a Unix stream socket at `$CABOOSE_VIDEO_SOCKET`, default
//! `$XDG_RUNTIME_DIR/caboose-video.sock`. Every message is a type byte, a little-endian
//! u32 payload length and a fixed little-endian payload (`proto.h`); FRAME and HELLO end
//! in variable data.

pub const PROTO_VERSION: u16 = 1;

/// Driver → compositor.
#[derive(Debug, Clone, PartialEq)]
pub enum DriverMessage {
    Hello { version: u16, pid: u32, program: String },
    Open { stream: u32, codec: u8, profile: u8, bit_depth: u8, chroma: u8, width: u16, height: u16 },
    Frame { stream: u32, seq: u32, surface: u32, flags: u8, t_us: u64, width: u16, height: u16, data: Vec<u8> },
    Surface { surface: u32, dev: u64, ino: u64 },
    Close { stream: u32, reason: u8 },
    SurfaceGone { surface: u32 },
}

pub mod codec {
    pub const H264: u8 = 1;
    pub const HEVC: u8 = 2;
    pub const VP9: u8 = 3;
    pub const AV1: u8 = 4;
}

pub mod frame_flags {
    /// A random access point: decoding can start here.
    pub const KEY: u8 = 0x01;
    /// Not shown when decoded; output only for the app to show later, if it does.
    pub const HIDDEN: u8 = 0x02;
    /// Resent after REPLAY.
    pub const REPLAY: u8 = 0x04;
}

pub mod close {
    pub const APP: u8 = 0;
    pub const READBACK: u8 = 1;
    pub const REQUESTED: u8 = 2;
    pub const UNSUPPORTED: u8 = 3;
    pub const ERROR: u8 = 4;

    pub fn name(reason: u8) -> &'static str {
        match reason {
            APP => "the application closed its decoder",
            READBACK => "the application read pixels back; decoding locally",
            REQUESTED => "decoding locally as asked",
            UNSUPPORTED => "the bitstream cannot be passed through; decoding locally",
            ERROR => "the socket failed",
            _ => "unknown reason",
        }
    }
}

pub mod mode {
    pub const PASSTHROUGH: u8 = 0;
    pub const DECODE: u8 = 1;
}

/// Compositor → driver.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum CompositorMessage {
    /// Carry this stream through (`mode::PASSTHROUGH`) marked with `tag`, or decode it
    /// locally (`mode::DECODE`).
    Accept { stream: u32, tag: u8, mode: u8 },
    /// Decode this stream locally from now on.
    Decode { stream: u32, reason: u8 },
    /// Resend from the last key frame.
    Replay { stream: u32 },
}

/// Why the compositor asks the driver to decode locally.
pub mod decode_reason {
    /// The client cannot decode this codec.
    pub const CLIENT_CODEC: u8 = 0;
    /// No marker tag is free.
    pub const NO_TAG: u8 = 1;
    /// The client keeps failing to decode the stream.
    pub const CLIENT_ERRORS: u8 = 2;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IpcError {
    UnknownType(u8),
    Short { type_id: u8, len: usize },
    TooLarge(usize),
}

/// The largest message accepted: an access unit of a 4K intra frame fits comfortably.
pub const MAX_PAYLOAD: usize = 32 * 1024 * 1024;

fn u16_at(b: &[u8], i: usize) -> u16 {
    u16::from_le_bytes([b[i], b[i + 1]])
}
fn u32_at(b: &[u8], i: usize) -> u32 {
    u32::from_le_bytes(b[i..i + 4].try_into().unwrap())
}
fn u64_at(b: &[u8], i: usize) -> u64 {
    u64::from_le_bytes(b[i..i + 8].try_into().unwrap())
}

impl DriverMessage {
    pub fn parse(type_id: u8, p: &[u8]) -> Result<Self, IpcError> {
        let need = |n: usize| if p.len() < n { Err(IpcError::Short { type_id, len: p.len() }) } else { Ok(()) };
        Ok(match type_id {
            0x01 => {
                need(8)?;
                DriverMessage::Hello {
                    version: u16_at(p, 0),
                    pid: u32_at(p, 4),
                    program: String::from_utf8_lossy(&p[8..]).trim_end_matches('\0').to_owned(),
                }
            }
            0x02 => {
                need(12)?;
                DriverMessage::Open {
                    stream: u32_at(p, 0),
                    codec: p[4],
                    profile: p[5],
                    bit_depth: p[6],
                    chroma: p[7],
                    width: u16_at(p, 8),
                    height: u16_at(p, 10),
                }
            }
            0x03 => {
                need(28)?;
                DriverMessage::Frame {
                    stream: u32_at(p, 0),
                    seq: u32_at(p, 4),
                    surface: u32_at(p, 8),
                    flags: p[12],
                    t_us: u64_at(p, 16),
                    width: u16_at(p, 24),
                    height: u16_at(p, 26),
                    data: p[28..].to_vec(),
                }
            }
            0x04 => {
                need(24)?;
                DriverMessage::Surface { surface: u32_at(p, 0), dev: u64_at(p, 8), ino: u64_at(p, 16) }
            }
            0x05 => {
                need(5)?;
                DriverMessage::Close { stream: u32_at(p, 0), reason: p[4] }
            }
            0x06 => {
                need(4)?;
                DriverMessage::SurfaceGone { surface: u32_at(p, 0) }
            }
            other => return Err(IpcError::UnknownType(other)),
        })
    }

    /// Encodes the message, as the driver does (for tests).
    #[cfg(test)]
    pub fn encode(&self) -> Vec<u8> {
        let (t, mut p) = match self {
            DriverMessage::Hello { version, pid, program } => {
                let mut p = version.to_le_bytes().to_vec();
                p.extend_from_slice(&0u16.to_le_bytes());
                p.extend_from_slice(&pid.to_le_bytes());
                p.extend_from_slice(program.as_bytes());
                (0x01, p)
            }
            DriverMessage::Open { stream, codec, profile, bit_depth, chroma, width, height } => {
                let mut p = stream.to_le_bytes().to_vec();
                p.extend_from_slice(&[*codec, *profile, *bit_depth, *chroma]);
                p.extend_from_slice(&width.to_le_bytes());
                p.extend_from_slice(&height.to_le_bytes());
                (0x02, p)
            }
            DriverMessage::Frame { stream, seq, surface, flags, t_us, width, height, data } => {
                let mut p = stream.to_le_bytes().to_vec();
                p.extend_from_slice(&seq.to_le_bytes());
                p.extend_from_slice(&surface.to_le_bytes());
                p.extend_from_slice(&[*flags, 0, 0, 0]);
                p.extend_from_slice(&t_us.to_le_bytes());
                p.extend_from_slice(&width.to_le_bytes());
                p.extend_from_slice(&height.to_le_bytes());
                p.extend_from_slice(data);
                (0x03, p)
            }
            DriverMessage::Surface { surface, dev, ino } => {
                let mut p = surface.to_le_bytes().to_vec();
                p.extend_from_slice(&0u32.to_le_bytes());
                p.extend_from_slice(&dev.to_le_bytes());
                p.extend_from_slice(&ino.to_le_bytes());
                (0x04, p)
            }
            DriverMessage::Close { stream, reason } => {
                let mut p = stream.to_le_bytes().to_vec();
                p.push(*reason);
                (0x05, p)
            }
            DriverMessage::SurfaceGone { surface } => (0x06, surface.to_le_bytes().to_vec()),
        };
        let mut out = vec![t];
        out.extend_from_slice(&(p.len() as u32).to_le_bytes());
        out.append(&mut p);
        out
    }
}

impl CompositorMessage {
    pub fn encode(&self) -> Vec<u8> {
        let (t, p): (u8, Vec<u8>) = match *self {
            CompositorMessage::Accept { stream, tag, mode } => {
                let mut p = stream.to_le_bytes().to_vec();
                p.extend_from_slice(&[tag, mode]);
                (0x81, p)
            }
            CompositorMessage::Decode { stream, reason } => {
                let mut p = stream.to_le_bytes().to_vec();
                p.push(reason);
                (0x82, p)
            }
            CompositorMessage::Replay { stream } => (0x83, stream.to_le_bytes().to_vec()),
        };
        let mut out = vec![t];
        out.extend_from_slice(&(p.len() as u32).to_le_bytes());
        out.extend_from_slice(&p);
        out
    }

    /// Decodes the message, as the driver does (for tests).
    #[cfg(test)]
    pub fn parse(type_id: u8, p: &[u8]) -> Result<Self, IpcError> {
        let need = |n: usize| if p.len() < n { Err(IpcError::Short { type_id, len: p.len() }) } else { Ok(()) };
        Ok(match type_id {
            0x81 => {
                need(6)?;
                CompositorMessage::Accept { stream: u32_at(p, 0), tag: p[4], mode: p[5] }
            }
            0x82 => {
                need(5)?;
                CompositorMessage::Decode { stream: u32_at(p, 0), reason: p[4] }
            }
            0x83 => {
                need(4)?;
                CompositorMessage::Replay { stream: u32_at(p, 0) }
            }
            other => return Err(IpcError::UnknownType(other)),
        })
    }
}

/// Splits a byte stream into (type, payload) messages.
#[derive(Default)]
pub struct Framer {
    buf: Vec<u8>,
}

impl Framer {
    pub fn push(&mut self, bytes: &[u8]) {
        self.buf.extend_from_slice(bytes);
    }

    pub fn next_message(&mut self) -> Result<Option<(u8, Vec<u8>)>, IpcError> {
        if self.buf.len() < 5 {
            return Ok(None);
        }
        let len = u32_at(&self.buf, 1) as usize;
        if len > MAX_PAYLOAD {
            return Err(IpcError::TooLarge(len));
        }
        if self.buf.len() < 5 + len {
            return Ok(None);
        }
        let t = self.buf[0];
        let payload = self.buf[5..5 + len].to_vec();
        self.buf.drain(..5 + len);
        Ok(Some((t, payload)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn round_trip(m: DriverMessage) {
        let bytes = m.encode();
        let mut f = Framer::default();
        f.push(&bytes);
        let (t, p) = f.next_message().unwrap().unwrap();
        assert_eq!(DriverMessage::parse(t, &p).unwrap(), m);
    }

    #[test]
    fn driver_messages_round_trip() {
        round_trip(DriverMessage::Hello { version: 1, pid: 4242, program: "chromium".into() });
        round_trip(DriverMessage::Open {
            stream: 3,
            codec: codec::HEVC,
            profile: 1,
            bit_depth: 10,
            chroma: 1,
            width: 3840,
            height: 2160,
        });
        round_trip(DriverMessage::Frame {
            stream: 3,
            seq: 77,
            surface: 9,
            flags: frame_flags::KEY | frame_flags::HIDDEN,
            t_us: 123_456_789,
            width: 3840,
            height: 2160,
            data: vec![0, 0, 0, 1, 0x40],
        });
        round_trip(DriverMessage::Surface { surface: 9, dev: 0xfd00, ino: 123456 });
        round_trip(DriverMessage::Close { stream: 3, reason: close::READBACK });
        round_trip(DriverMessage::SurfaceGone { surface: 9 });
    }

    #[test]
    fn layouts_match_proto_h() {
        // OPEN: u32 stream, u8 codec, u8 profile, u8 bit_depth, u8 chroma, u16 w, u16 h.
        let open =
            DriverMessage::Open { stream: 1, codec: 2, profile: 3, bit_depth: 8, chroma: 1, width: 1920, height: 1080 }
                .encode();
        assert_eq!(open, [0x02, 12, 0, 0, 0, 1, 0, 0, 0, 2, 3, 8, 1, 0x80, 0x07, 0x38, 0x04]);
        // ACCEPT: u32 stream, u8 tag, u8 mode.
        assert_eq!(
            CompositorMessage::Accept { stream: 5, tag: 63, mode: mode::PASSTHROUGH }.encode(),
            [0x81, 6, 0, 0, 0, 5, 0, 0, 0, 63, 0]
        );
        // FRAME's data starts at byte 28 of the payload.
        let frame = DriverMessage::Frame {
            stream: 1,
            seq: 2,
            surface: 3,
            flags: 1,
            t_us: 4,
            width: 5,
            height: 6,
            data: vec![0xaa],
        }
        .encode();
        assert_eq!(frame.len(), 5 + 28 + 1);
        assert_eq!(frame[5 + 28], 0xaa);
    }

    #[test]
    fn compositor_messages_round_trip() {
        for m in [
            CompositorMessage::Accept { stream: 9, tag: 12, mode: mode::PASSTHROUGH },
            CompositorMessage::Decode { stream: 9, reason: decode_reason::CLIENT_CODEC },
            CompositorMessage::Replay { stream: 9 },
        ] {
            let bytes = m.encode();
            assert_eq!(CompositorMessage::parse(bytes[0], &bytes[5..]).unwrap(), m);
        }
    }

    #[test]
    fn short_and_unknown_messages_are_errors() {
        assert_eq!(DriverMessage::parse(0x02, &[0; 4]), Err(IpcError::Short { type_id: 2, len: 4 }));
        assert_eq!(DriverMessage::parse(0x7f, &[]), Err(IpcError::UnknownType(0x7f)));
        let mut f = Framer::default();
        f.push(&[0x03, 0xff, 0xff, 0xff, 0x7f]);
        assert!(matches!(f.next_message(), Err(IpcError::TooLarge(_))));
    }
}

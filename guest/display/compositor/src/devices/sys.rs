//! The kernel interfaces the phone's devices are made with: ioctl numbers and the C
//! structures of uinput (`linux/uinput.h`), evdev (`linux/input.h`), V4L2
//! (`linux/videodev2.h`) and v4l2loopback's control device (`v4l2loopback.h`, 0.15).
//! UHID's packed events are laid out by hand in `uhid.rs`.

use std::ffi::CString;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::path::Path;

const IOC_WRITE: u64 = 1;
const IOC_READ: u64 = 2;

/// `_IOC(dir, type, nr, size)` for the generic layout x86-64 and arm64 share.
pub const fn ioc(dir: u64, ty: u8, nr: u8, size: usize) -> u64 {
    (dir << 30) | ((size as u64) << 16) | ((ty as u64) << 8) | nr as u64
}
pub const fn io(ty: u8, nr: u8) -> u64 {
    ioc(0, ty, nr, 0)
}
pub const fn iow<T>(ty: u8, nr: u8) -> u64 {
    ioc(IOC_WRITE, ty, nr, std::mem::size_of::<T>())
}
pub const fn ior<T>(ty: u8, nr: u8) -> u64 {
    ioc(IOC_READ, ty, nr, std::mem::size_of::<T>())
}
pub const fn iowr<T>(ty: u8, nr: u8) -> u64 {
    ioc(IOC_READ | IOC_WRITE, ty, nr, std::mem::size_of::<T>())
}

/// `ioctl(fd, request, arg)` with a pointer argument.
pub fn ioctl_ptr<T>(fd: &impl AsRawFd, request: u64, arg: *mut T) -> io::Result<i32> {
    // SAFETY: the request numbers in this module are built from the size of `T`, so the
    // kernel reads and writes exactly the structure `arg` points to.
    let r = unsafe { libc::ioctl(fd.as_raw_fd(), request as _, arg) };
    if r < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(r)
    }
}

/// `ioctl(fd, request, value)` with an integer argument.
pub fn ioctl_int(fd: &impl AsRawFd, request: u64, value: libc::c_ulong) -> io::Result<i32> {
    // SAFETY: these requests take their argument by value.
    let r = unsafe { libc::ioctl(fd.as_raw_fd(), request as _, value) };
    if r < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(r)
    }
}

/// Opens a device node read-write, close-on-exec, optionally non-blocking.
pub fn open_rw(path: &Path, nonblocking: bool) -> io::Result<OwnedFd> {
    let c = CString::new(path.as_os_str().as_encoded_bytes()).map_err(|_| io::ErrorKind::InvalidInput)?;
    let flags = libc::O_RDWR | libc::O_CLOEXEC | if nonblocking { libc::O_NONBLOCK } else { 0 };
    // SAFETY: `c` is a valid NUL-terminated path.
    let fd = unsafe { libc::open(c.as_ptr(), flags) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: open returned a new descriptor that nothing else owns.
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

/// Writes all of `data` with one `write` (devices take a whole event or picture at once).
pub fn write_all(fd: &impl AsRawFd, data: &[u8]) -> io::Result<()> {
    // SAFETY: the pointer and length describe `data`.
    let n = unsafe { libc::write(fd.as_raw_fd(), data.as_ptr().cast(), data.len()) };
    if n < 0 {
        Err(io::Error::last_os_error())
    } else if n as usize != data.len() {
        Err(io::Error::new(io::ErrorKind::WriteZero, format!("short write: {n} of {}", data.len())))
    } else {
        Ok(())
    }
}

/// Reads into `buf`; `Ok(None)` when a non-blocking descriptor has nothing.
pub fn read_some(fd: &impl AsRawFd, buf: &mut [u8]) -> io::Result<Option<usize>> {
    // SAFETY: the pointer and length describe `buf`.
    let n = unsafe { libc::read(fd.as_raw_fd(), buf.as_mut_ptr().cast(), buf.len()) };
    if n < 0 {
        let e = io::Error::last_os_error();
        if e.kind() == io::ErrorKind::WouldBlock {
            return Ok(None);
        }
        return Err(e);
    }
    Ok(Some(n as usize))
}

// ---- evdev and uinput ----

pub const EV_SYN: u16 = 0x00;
pub const EV_KEY: u16 = 0x01;
pub const EV_ABS: u16 = 0x03;
pub const EV_MSC: u16 = 0x04;
pub const EV_FF: u16 = 0x15;
pub const EV_UINPUT: u16 = 0x0101;
pub const SYN_REPORT: u16 = 0;
pub const MSC_TIMESTAMP: u16 = 0x05;

pub const ABS_X: u16 = 0x00;
pub const ABS_Y: u16 = 0x01;
pub const ABS_Z: u16 = 0x02;
pub const ABS_RX: u16 = 0x03;
pub const ABS_RY: u16 = 0x04;
pub const ABS_RZ: u16 = 0x05;
pub const ABS_HAT0X: u16 = 0x10;
pub const ABS_HAT0Y: u16 = 0x11;

pub const BTN_A: u16 = 0x130;
pub const BTN_B: u16 = 0x131;
pub const BTN_X: u16 = 0x133;
pub const BTN_Y: u16 = 0x134;
pub const BTN_TL: u16 = 0x136;
pub const BTN_TR: u16 = 0x137;
pub const BTN_SELECT: u16 = 0x13a;
pub const BTN_START: u16 = 0x13b;
pub const BTN_MODE: u16 = 0x13c;
pub const BTN_THUMBL: u16 = 0x13d;
pub const BTN_THUMBR: u16 = 0x13e;

pub const KEY_VOLUMEDOWN: u16 = 114;
pub const KEY_VOLUMEUP: u16 = 115;
pub const KEY_PROG1: u16 = 148;
pub const KEY_CAMERA: u16 = 212;

pub const FF_RUMBLE: u16 = 0x50;
pub const FF_GAIN: u16 = 0x60;
pub const INPUT_PROP_ACCELEROMETER: u16 = 0x06;

pub const BUS_USB: u16 = 0x03;
pub const BUS_VIRTUAL: u16 = 0x06;

pub const UI_FF_UPLOAD: u16 = 1;
pub const UI_FF_ERASE: u16 = 2;

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct InputId {
    pub bustype: u16,
    pub vendor: u16,
    pub product: u16,
    pub version: u16,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct UinputSetup {
    pub id: InputId,
    pub name: [u8; 80],
    pub ff_effects_max: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct InputAbsinfo {
    pub value: i32,
    pub minimum: i32,
    pub maximum: i32,
    pub fuzz: i32,
    pub flat: i32,
    pub resolution: i32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct UinputAbsSetup {
    pub code: u16,
    pub absinfo: InputAbsinfo,
}

/// `struct input_event` with a 64-bit `struct timeval`.
#[repr(C)]
#[derive(Clone, Copy, Default, Debug)]
pub struct InputEvent {
    pub sec: i64,
    pub usec: i64,
    pub kind: u16,
    pub code: u16,
    pub value: i32,
}

/// `struct ff_effect` (48 bytes on 64-bit): the union is kept as bytes; a rumble's
/// strong and weak magnitudes are its first two `u16`s.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct FfEffect {
    pub kind: u16,
    pub id: i16,
    pub direction: u16,
    pub trigger_button: u16,
    pub trigger_interval: u16,
    pub replay_length: u16,
    pub replay_delay: u16,
    pub union: [u64; 4],
}

impl FfEffect {
    pub fn rumble(&self) -> (u16, u16) {
        let first = self.union[0].to_ne_bytes();
        (u16::from_ne_bytes([first[0], first[1]]), u16::from_ne_bytes([first[2], first[3]]))
    }
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct UinputFfUpload {
    pub request_id: u32,
    pub retval: i32,
    pub effect: FfEffect,
    pub old: FfEffect,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct UinputFfErase {
    pub request_id: u32,
    pub retval: i32,
    pub effect_id: u32,
}

pub const UI_DEV_CREATE: u64 = io(b'U', 1);
pub const UI_DEV_DESTROY: u64 = io(b'U', 2);
pub const UI_DEV_SETUP: u64 = iow::<UinputSetup>(b'U', 3);
pub const UI_ABS_SETUP: u64 = iow::<UinputAbsSetup>(b'U', 4);
pub const UI_SET_EVBIT: u64 = iow::<libc::c_int>(b'U', 100);
pub const UI_SET_KEYBIT: u64 = iow::<libc::c_int>(b'U', 101);
pub const UI_SET_ABSBIT: u64 = iow::<libc::c_int>(b'U', 103);
pub const UI_SET_MSCBIT: u64 = iow::<libc::c_int>(b'U', 104);
pub const UI_SET_FFBIT: u64 = iow::<libc::c_int>(b'U', 107);
pub const UI_SET_PROPBIT: u64 = iow::<libc::c_int>(b'U', 110);
pub const UI_BEGIN_FF_UPLOAD: u64 = iowr::<UinputFfUpload>(b'U', 200);
pub const UI_END_FF_UPLOAD: u64 = iow::<UinputFfUpload>(b'U', 201);
pub const UI_BEGIN_FF_ERASE: u64 = iowr::<UinputFfErase>(b'U', 202);
pub const UI_END_FF_ERASE: u64 = iow::<UinputFfErase>(b'U', 203);
/// `UI_GET_SYSNAME(len)`.
pub const fn ui_get_sysname(len: usize) -> u64 {
    ioc(IOC_READ, b'U', 44, len)
}

// ---- V4L2 ----

pub const V4L2_BUF_TYPE_VIDEO_OUTPUT: u32 = 2;
pub const V4L2_FIELD_NONE: u32 = 1;
pub const V4L2_COLORSPACE_SRGB: u32 = 8;
pub const V4L2_COLORSPACE_RAW: u32 = 11;

pub const fn fourcc(code: &[u8; 4]) -> u32 {
    code[0] as u32 | (code[1] as u32) << 8 | (code[2] as u32) << 16 | (code[3] as u32) << 24
}
pub const V4L2_PIX_FMT_YUYV: u32 = fourcc(b"YUYV");
pub const V4L2_PIX_FMT_Z16: u32 = fourcc(b"Z16 ");

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct V4l2PixFormat {
    pub width: u32,
    pub height: u32,
    pub pixelformat: u32,
    pub field: u32,
    pub bytesperline: u32,
    pub sizeimage: u32,
    pub colorspace: u32,
    pub private: u32,
    pub flags: u32,
    pub ycbcr_enc: u32,
    pub quantization: u32,
    pub xfer_func: u32,
}

/// `struct v4l2_format`: the union is 200 bytes and 8-byte aligned.
#[repr(C)]
pub struct V4l2Format {
    pub kind: u32,
    _pad: u32,
    pub pix: V4l2PixFormat,
    _rest: [u8; 200 - std::mem::size_of::<V4l2PixFormat>()],
    _align: [u64; 0],
}

impl V4l2Format {
    pub fn output(pix: V4l2PixFormat) -> Self {
        Self { kind: V4L2_BUF_TYPE_VIDEO_OUTPUT, _pad: 0, pix, _rest: [0; 200 - std::mem::size_of::<V4l2PixFormat>()], _align: [] }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct V4l2Fract {
    pub numerator: u32,
    pub denominator: u32,
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct V4l2OutputParm {
    pub capability: u32,
    pub outputmode: u32,
    pub timeperframe: V4l2Fract,
    pub extendedmode: u32,
    pub writebuffers: u32,
    pub reserved: [u32; 4],
}

/// `struct v4l2_streamparm`: a 200-byte union of 32-bit fields.
#[repr(C)]
pub struct V4l2StreamParm {
    pub kind: u32,
    pub output: V4l2OutputParm,
    _rest: [u8; 200 - std::mem::size_of::<V4l2OutputParm>()],
}

impl V4l2StreamParm {
    pub fn output(fps: u32) -> Self {
        Self {
            kind: V4L2_BUF_TYPE_VIDEO_OUTPUT,
            output: V4l2OutputParm { timeperframe: V4l2Fract { numerator: 1, denominator: fps }, ..Default::default() },
            _rest: [0; 200 - std::mem::size_of::<V4l2OutputParm>()],
        }
    }
}

#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct V4l2EventSubscription {
    pub kind: u32,
    pub id: u32,
    pub flags: u32,
    pub reserved: [u32; 5],
}

/// `struct v4l2_event` (136 bytes on 64-bit).
#[repr(C)]
#[derive(Clone, Copy)]
pub struct V4l2Event {
    pub kind: u32,
    pub data: [u64; 8],
    pub pending: u32,
    pub sequence: u32,
    pub timestamp: [i64; 2],
    pub id: u32,
    pub reserved: [u32; 8],
}

impl Default for V4l2Event {
    fn default() -> Self {
        Self { kind: 0, data: [0; 8], pending: 0, sequence: 0, timestamp: [0; 2], id: 0, reserved: [0; 8] }
    }
}

pub const VIDIOC_S_FMT: u64 = iowr::<V4l2Format>(b'V', 5);
pub const VIDIOC_S_PARM: u64 = iowr::<V4l2StreamParm>(b'V', 22);
pub const VIDIOC_DQEVENT: u64 = ior::<V4l2Event>(b'V', 89);
pub const VIDIOC_SUBSCRIBE_EVENT: u64 = iow::<V4l2EventSubscription>(b'V', 90);

/// v4l2loopback's event for the number of readers streaming (0 or 1).
pub const V4L2_EVENT_PRI_CLIENT_USAGE: u32 = 0x0800_0000 + 0x08E0_0000 + 1;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct LoopbackConfig {
    pub output_nr: i32,
    pub unused: i32,
    pub card_label: [u8; 32],
    pub min_width: u32,
    pub max_width: u32,
    pub min_height: u32,
    pub max_height: u32,
    pub max_buffers: i32,
    pub max_openers: i32,
    pub debug: i32,
    pub announce_all_caps: i32,
}

pub const V4L2LOOPBACK_CTL_ADD: u64 = iow::<LoopbackConfig>(b'~', 1);
pub const V4L2LOOPBACK_CTL_REMOVE: u64 = iow::<u32>(b'~', 2);

/// Copies `text` into a fixed C string field, truncated on a character boundary and
/// always NUL-terminated.
pub fn c_field<const N: usize>(text: &str) -> [u8; N] {
    let mut out = [0u8; N];
    let mut end = text.len().min(N - 1);
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    out[..end].copy_from_slice(&text.as_bytes()[..end]);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::mem::size_of;

    #[test]
    fn structures_match_the_kernel_abi() {
        assert_eq!(size_of::<UinputSetup>(), 92);
        assert_eq!(size_of::<UinputAbsSetup>(), 28);
        assert_eq!(size_of::<InputEvent>(), 24);
        assert_eq!(size_of::<FfEffect>(), 48);
        assert_eq!(size_of::<UinputFfUpload>(), 104);
        assert_eq!(size_of::<UinputFfErase>(), 12);
        assert_eq!(size_of::<V4l2Format>(), 208);
        assert_eq!(std::mem::offset_of!(V4l2Format, pix), 8);
        assert_eq!(std::mem::offset_of!(V4l2Event, pending), 72);
        assert_eq!(std::mem::offset_of!(UinputFfUpload, old), 56);
        assert_eq!(size_of::<V4l2StreamParm>(), 204);
        assert_eq!(size_of::<V4l2EventSubscription>(), 32);
        assert_eq!(size_of::<V4l2Event>(), 136);
        assert_eq!(size_of::<LoopbackConfig>(), 72);
    }

    #[test]
    fn ioctl_numbers_match_the_headers() {
        // Values from the C headers on x86-64 and arm64.
        assert_eq!(UI_DEV_CREATE, 0x5501);
        assert_eq!(UI_DEV_SETUP, 0x405c_5503);
        assert_eq!(UI_ABS_SETUP, 0x401c_5504);
        assert_eq!(UI_SET_EVBIT, 0x4004_5564);
        assert_eq!(UI_BEGIN_FF_UPLOAD, 0xc068_55c8);
        assert_eq!(UI_END_FF_ERASE, 0x400c_55cb);
        assert_eq!(VIDIOC_S_FMT, 0xc0d0_5605);
        assert_eq!(VIDIOC_S_PARM, 0xc0cc_5616);
        assert_eq!(VIDIOC_DQEVENT, 0x8088_5659);
        assert_eq!(VIDIOC_SUBSCRIBE_EVENT, 0x4020_565a);
        assert_eq!(V4L2LOOPBACK_CTL_ADD, 0x4048_7e01);
    }

    #[test]
    fn rumble_magnitudes_come_from_the_union() {
        let mut e = FfEffect {
            kind: FF_RUMBLE,
            id: 0,
            direction: 0,
            trigger_button: 0,
            trigger_interval: 0,
            replay_length: 250,
            replay_delay: 0,
            union: [0; 4],
        };
        let mut first = [0u8; 8];
        first[..2].copy_from_slice(&0xffffu16.to_ne_bytes());
        first[2..4].copy_from_slice(&0x4000u16.to_ne_bytes());
        e.union[0] = u64::from_ne_bytes(first);
        assert_eq!(e.rumble(), (0xffff, 0x4000));
    }

    #[test]
    fn c_fields_truncate_on_character_boundaries() {
        let f: [u8; 8] = c_field("iPhone é camera");
        assert_eq!(&f, b"iPhone \0");
        let g: [u8; 4] = c_field("ab");
        assert_eq!(&g, b"ab\0\0");
    }
}

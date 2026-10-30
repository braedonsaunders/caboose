//! Gamepads, the motion device and the phone's buttons as uinput devices
//! (docs/devices.md, "Input devices").

use super::sys::*;
use caboose_display_protocol::{gamepad_buttons as gb, DeviceKey, MotionSample};
use std::collections::HashMap;
use std::io;
use std::os::fd::{AsRawFd, OwnedFd};
use std::path::{Path, PathBuf};

pub const UINPUT: &str = "/dev/uinput";
/// The physical path every device made from the phone's hardware carries; udev rules give
/// the owner's applications its event nodes by it.
pub const PHYS: &std::ffi::CStr = c"caboose/phone";

/// What a uinput device is made of before it is created.
pub struct Spec {
    pub name: String,
    pub id: InputId,
    pub keys: Vec<u16>,
    pub abs: Vec<(u16, InputAbsinfo)>,
    pub props: Vec<u16>,
    pub msc: Vec<u16>,
    /// Takes `FF_RUMBLE` effects.
    pub rumble: bool,
}

/// A rumble the kernel asked a device to play: magnitudes 0…1 and its length.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rumble {
    pub strong: f64,
    pub weak: f64,
    pub ms: u32,
}

/// A created uinput device.
pub struct Device {
    fd: OwnedFd,
    /// `/dev/input/eventN`, once udev or devtmpfs has made it.
    pub node: Option<PathBuf>,
    /// Uploaded effects by id: strong, weak, length in ms.
    effects: HashMap<i16, (u16, u16, u16)>,
    gain: f64,
}

fn absinfo(minimum: i32, maximum: i32, fuzz: i32, flat: i32, resolution: i32) -> InputAbsinfo {
    InputAbsinfo { value: 0, minimum, maximum, fuzz, flat, resolution }
}

impl Spec {
    /// A gamepad with the Xbox 360 controller's identity and layout, which SDL, Steam and
    /// browsers map.
    pub fn gamepad(name: &str, rumble: bool) -> Self {
        let stick = absinfo(-32768, 32767, 16, 128, 0);
        let trigger = absinfo(0, 255, 0, 0, 0);
        let hat = absinfo(-1, 1, 0, 0, 0);
        Self {
            name: name.into(),
            id: InputId { bustype: BUS_USB, vendor: 0x045e, product: 0x028e, version: 0x0110 },
            keys: vec![
                BTN_A, BTN_B, BTN_X, BTN_Y, BTN_TL, BTN_TR, BTN_SELECT, BTN_START, BTN_MODE, BTN_THUMBL, BTN_THUMBR,
            ],
            abs: vec![
                (ABS_X, stick),
                (ABS_Y, stick),
                (ABS_Z, trigger),
                (ABS_RX, stick),
                (ABS_RY, stick),
                (ABS_RZ, trigger),
                (ABS_HAT0X, hat),
                (ABS_HAT0Y, hat),
            ],
            props: vec![],
            msc: vec![],
            rumble,
        }
    }

    /// The phone's accelerometer and gyroscope, as Linux's controller drivers report motion.
    pub fn motion(name: &str) -> Self {
        let accel = absinfo(-ACCEL_PER_G * 16, ACCEL_PER_G * 16, 4, 0, ACCEL_PER_G);
        let gyro = absinfo(-GYRO_PER_DEG * 2000, GYRO_PER_DEG * 2000, 16, 0, GYRO_PER_DEG);
        Self {
            name: name.into(),
            id: InputId { bustype: BUS_VIRTUAL, vendor: 0, product: 0, version: 1 },
            keys: vec![],
            abs: vec![(ABS_X, accel), (ABS_Y, accel), (ABS_Z, accel), (ABS_RX, gyro), (ABS_RY, gyro), (ABS_RZ, gyro)],
            props: vec![INPUT_PROP_ACCELEROMETER],
            msc: vec![MSC_TIMESTAMP],
            rumble: false,
        }
    }

    pub fn buttons(name: &str, keys: &[DeviceKey]) -> Self {
        Self {
            name: name.into(),
            id: InputId { bustype: BUS_VIRTUAL, vendor: 0, product: 0, version: 1 },
            keys: keys.iter().map(|&k| key_code(k)).collect(),
            abs: vec![],
            props: vec![],
            msc: vec![],
            rumble: false,
        }
    }
}

/// Accelerometer units per g and gyroscope units per degree per second.
pub const ACCEL_PER_G: i32 = 8192;
pub const GYRO_PER_DEG: i32 = 1024;
const STANDARD_GRAVITY: f64 = 9.80665;

pub fn key_code(key: DeviceKey) -> u16 {
    match key {
        DeviceKey::VolumeUp => KEY_VOLUMEUP,
        DeviceKey::VolumeDown => KEY_VOLUMEDOWN,
        DeviceKey::Camera => KEY_CAMERA,
        DeviceKey::Action => KEY_PROG1,
    }
}

fn event(kind: u16, code: u16, value: i32) -> InputEvent {
    InputEvent { sec: 0, usec: 0, kind, code, value }
}

/// A gamepad state as the events that set it, ending in `SYN_REPORT`.
pub fn gamepad_events(buttons: u32, axes: &[f64; 6]) -> Vec<InputEvent> {
    let pressed = |bit: u32| i32::from(buttons & bit != 0);
    let stick = |v: f64| (v.clamp(-1.0, 1.0) * 32767.0).round() as i32;
    let trigger = |v: f64| (v.clamp(0.0, 1.0) * 255.0).round() as i32;
    let mut out = vec![
        event(EV_KEY, BTN_A, pressed(gb::SOUTH)),
        event(EV_KEY, BTN_B, pressed(gb::EAST)),
        // Linux's BTN_X and BTN_Y are the Xbox controller's X (west) and Y (north), as xpad
        // reports them.
        event(EV_KEY, BTN_X, pressed(gb::WEST)),
        event(EV_KEY, BTN_Y, pressed(gb::NORTH)),
        event(EV_KEY, BTN_TL, pressed(gb::LEFT_SHOULDER)),
        event(EV_KEY, BTN_TR, pressed(gb::RIGHT_SHOULDER)),
        event(EV_KEY, BTN_SELECT, pressed(gb::VIEW)),
        event(EV_KEY, BTN_START, pressed(gb::MENU)),
        event(EV_KEY, BTN_MODE, pressed(gb::HOME)),
        event(EV_KEY, BTN_THUMBL, pressed(gb::LEFT_STICK)),
        event(EV_KEY, BTN_THUMBR, pressed(gb::RIGHT_STICK)),
        // Up is positive on the phone and down is positive in evdev.
        event(EV_ABS, ABS_X, stick(axes[0])),
        event(EV_ABS, ABS_Y, -stick(axes[1])),
        event(EV_ABS, ABS_RX, stick(axes[2])),
        event(EV_ABS, ABS_RY, -stick(axes[3])),
        event(EV_ABS, ABS_Z, trigger(axes[4])),
        event(EV_ABS, ABS_RZ, trigger(axes[5])),
        event(EV_ABS, ABS_HAT0X, pressed(gb::DPAD_RIGHT) - pressed(gb::DPAD_LEFT)),
        event(EV_ABS, ABS_HAT0Y, pressed(gb::DPAD_DOWN) - pressed(gb::DPAD_UP)),
    ];
    out.push(event(EV_SYN, SYN_REPORT, 0));
    out
}

/// One motion sample as events, or nothing if it has neither acceleration nor rotation.
/// `MSC_TIMESTAMP` is microseconds, wrapping at 32 bits as the kernel's drivers report it.
pub fn motion_events(sample: &MotionSample) -> Vec<InputEvent> {
    let mut out = Vec::new();
    if let Some(a) = sample.accel {
        for (code, v) in [(ABS_X, a[0]), (ABS_Y, a[1]), (ABS_Z, a[2])] {
            out.push(event(EV_ABS, code, (v / STANDARD_GRAVITY * ACCEL_PER_G as f64).round() as i32));
        }
    }
    if let Some(g) = sample.gyro {
        for (code, v) in [(ABS_RX, g[0]), (ABS_RY, g[1]), (ABS_RZ, g[2])] {
            out.push(event(EV_ABS, code, (v.to_degrees() * GYRO_PER_DEG as f64).round() as i32));
        }
    }
    if out.is_empty() {
        return out;
    }
    out.push(event(EV_MSC, MSC_TIMESTAMP, sample.t_us as u32 as i32));
    out.push(event(EV_SYN, SYN_REPORT, 0));
    out
}

fn as_bytes(events: &[InputEvent]) -> &[u8] {
    // SAFETY: InputEvent is plain old data with no padding (24 bytes of integers).
    unsafe { std::slice::from_raw_parts(events.as_ptr().cast(), std::mem::size_of_val(events)) }
}

impl Device {
    pub fn create(spec: &Spec) -> io::Result<Self> {
        let fd = open_rw(Path::new(UINPUT), true)?;
        let bit = |request: u64, value: u16| ioctl_int(&fd, request, value as libc::c_ulong).map(|_| ());
        if !spec.keys.is_empty() {
            bit(UI_SET_EVBIT, EV_KEY)?;
            for &k in &spec.keys {
                bit(UI_SET_KEYBIT, k)?;
            }
        }
        if !spec.abs.is_empty() {
            bit(UI_SET_EVBIT, EV_ABS)?;
        }
        if !spec.msc.is_empty() {
            bit(UI_SET_EVBIT, EV_MSC)?;
            for &m in &spec.msc {
                bit(UI_SET_MSCBIT, m)?;
            }
        }
        for &p in &spec.props {
            bit(UI_SET_PROPBIT, p)?;
        }
        ioctl_int(&fd, UI_SET_PHYS, PHYS.as_ptr() as libc::c_ulong)?;
        if spec.rumble {
            bit(UI_SET_EVBIT, EV_FF)?;
            bit(UI_SET_FFBIT, FF_RUMBLE)?;
            bit(UI_SET_FFBIT, FF_GAIN)?;
        }
        for &(code, info) in &spec.abs {
            bit(UI_SET_ABSBIT, code)?;
            let mut setup = UinputAbsSetup { code, absinfo: info };
            ioctl_ptr(&fd, UI_ABS_SETUP, &mut setup)?;
        }
        let mut setup = UinputSetup {
            id: spec.id,
            name: c_field(&spec.name),
            ff_effects_max: if spec.rumble { 16 } else { 0 },
        };
        ioctl_ptr(&fd, UI_DEV_SETUP, &mut setup)?;
        ioctl_int(&fd, UI_DEV_CREATE, 0)?;
        let mut device = Self { fd, node: None, effects: HashMap::new(), gain: 1.0 };
        device.node = device.find_node();
        Ok(device)
    }

    /// `/dev/input/eventN` from the device's sysfs name.
    fn find_node(&self) -> Option<PathBuf> {
        let mut name = [0u8; 64];
        ioctl_ptr(&self.fd, ui_get_sysname(name.len()), name.as_mut_ptr()).ok()?;
        let end = name.iter().position(|&b| b == 0)?;
        let sys = std::str::from_utf8(&name[..end]).ok()?;
        let dir = Path::new("/sys/devices/virtual/input").join(sys);
        std::fs::read_dir(dir).ok()?.flatten().find_map(|e| {
            let n = e.file_name().into_string().ok()?;
            n.starts_with("event").then(|| Path::new("/dev/input").join(n))
        })
    }

    /// The node, looked up again if it was not there at creation.
    pub fn node(&mut self) -> Option<PathBuf> {
        if self.node.is_none() {
            self.node = self.find_node();
        }
        self.node.clone()
    }

    pub fn emit(&self, events: &[InputEvent]) -> io::Result<()> {
        if events.is_empty() {
            return Ok(());
        }
        write_all(&self.fd, as_bytes(events))
    }

    pub fn press(&self, code: u16, pressed: bool) -> io::Result<()> {
        self.emit(&[event(EV_KEY, code, i32::from(pressed)), event(EV_SYN, SYN_REPORT, 0)])
    }

    pub fn raw_fd(&self) -> i32 {
        self.fd.as_raw_fd()
    }

    /// Handles what the kernel queued for the device: effect uploads and erasures, which
    /// must be answered, and effects started or stopped. Returns the rumble to play, the
    /// last one asked for if several arrived.
    pub fn service(&mut self) -> io::Result<Option<Rumble>> {
        let mut rumble = None;
        let mut buf = [InputEvent::default(); 16];
        loop {
            // SAFETY: InputEvent is plain old data; the kernel writes whole events.
            let bytes = unsafe {
                std::slice::from_raw_parts_mut(buf.as_mut_ptr().cast::<u8>(), std::mem::size_of_val(&buf))
            };
            let Some(n) = read_some(&self.fd, bytes)? else { break };
            let count = n / std::mem::size_of::<InputEvent>();
            if count == 0 {
                break;
            }
            for e in &buf[..count] {
                match (e.kind, e.code) {
                    (EV_UINPUT, UI_FF_UPLOAD) => self.upload(e.value as u32)?,
                    (EV_UINPUT, UI_FF_ERASE) => self.erase(e.value as u32)?,
                    (EV_FF, FF_GAIN) => self.gain = (e.value.clamp(0, 0xffff) as f64) / 65535.0,
                    (EV_FF, id) => {
                        if e.value > 0 {
                            if let Some(&(strong, weak, length)) = self.effects.get(&(id as i16)) {
                                rumble = Some(Rumble {
                                    strong: strong as f64 / 65535.0 * self.gain,
                                    weak: weak as f64 / 65535.0 * self.gain,
                                    // An effect without a length plays until stopped; the phone
                                    // is told a long one and the stop that follows.
                                    ms: if length == 0 { 10_000 } else { (length as u32).saturating_mul(e.value as u32).min(60_000) },
                                });
                            }
                        } else {
                            rumble = Some(Rumble { strong: 0.0, weak: 0.0, ms: 0 });
                        }
                    }
                    _ => {}
                }
            }
        }
        Ok(rumble)
    }

    fn upload(&mut self, request_id: u32) -> io::Result<()> {
        // SAFETY: an all-zero UinputFfUpload is valid; the kernel fills it in.
        let mut up: UinputFfUpload = unsafe { std::mem::zeroed() };
        up.request_id = request_id;
        ioctl_ptr(&self.fd, UI_BEGIN_FF_UPLOAD, &mut up)?;
        if up.effect.kind == FF_RUMBLE {
            let (strong, weak) = up.effect.rumble();
            self.effects.insert(up.effect.id, (strong, weak, up.effect.replay_length));
            up.retval = 0;
        } else {
            up.retval = -libc::EINVAL;
        }
        ioctl_ptr(&self.fd, UI_END_FF_UPLOAD, &mut up)?;
        Ok(())
    }

    fn erase(&mut self, request_id: u32) -> io::Result<()> {
        let mut erase = UinputFfErase { request_id, ..Default::default() };
        ioctl_ptr(&self.fd, UI_BEGIN_FF_ERASE, &mut erase)?;
        self.effects.remove(&(erase.effect_id as i16));
        erase.retval = 0;
        ioctl_ptr(&self.fd, UI_END_FF_ERASE, &mut erase)?;
        Ok(())
    }
}

impl Drop for Device {
    fn drop(&mut self) {
        let _ = ioctl_int(&self.fd, UI_DEV_DESTROY, 0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn find(events: &[InputEvent], kind: u16, code: u16) -> i32 {
        events.iter().find(|e| e.kind == kind && e.code == code).map(|e| e.value).unwrap()
    }

    #[test]
    fn gamepad_state_maps_to_the_xbox_layout() {
        let e = gamepad_events(gb::SOUTH | gb::WEST | gb::DPAD_UP | gb::DPAD_LEFT, &[0.5, 1.0, -1.0, -0.25, 0.0, 0.5]);
        assert_eq!(find(&e, EV_KEY, BTN_A), 1);
        assert_eq!(find(&e, EV_KEY, BTN_B), 0);
        assert_eq!(find(&e, EV_KEY, BTN_X), 1, "the west button is Linux's BTN_X");
        assert_eq!(find(&e, EV_KEY, BTN_Y), 0);
        assert_eq!(find(&e, EV_ABS, ABS_X), 16384);
        assert_eq!(find(&e, EV_ABS, ABS_Y), -32767, "stick up is negative in evdev");
        assert_eq!(find(&e, EV_ABS, ABS_RX), -32767);
        assert_eq!(find(&e, EV_ABS, ABS_RY), 8192);
        assert_eq!(find(&e, EV_ABS, ABS_RZ), 128);
        assert_eq!(find(&e, EV_ABS, ABS_HAT0X), -1);
        assert_eq!(find(&e, EV_ABS, ABS_HAT0Y), -1);
        assert_eq!((e.last().unwrap().kind, e.last().unwrap().code), (EV_SYN, SYN_REPORT));
    }

    #[test]
    fn axes_out_of_range_are_clamped() {
        let e = gamepad_events(0, &[3.0, -3.0, 0.0, 0.0, 2.0, -1.0]);
        assert_eq!(find(&e, EV_ABS, ABS_X), 32767);
        assert_eq!(find(&e, EV_ABS, ABS_Y), 32767);
        assert_eq!(find(&e, EV_ABS, ABS_Z), 255);
        assert_eq!(find(&e, EV_ABS, ABS_RZ), 0);
    }

    #[test]
    fn motion_uses_the_drivers_resolutions() {
        let e = motion_events(&MotionSample {
            t_us: 5_000_000_123,
            accel: Some([0.0, 0.0, 9.80665]),
            gyro: Some([std::f64::consts::PI, 0.0, -0.5_f64.to_radians()]),
            ..Default::default()
        });
        assert_eq!(find(&e, EV_ABS, ABS_Z), ACCEL_PER_G, "1 g face up");
        assert_eq!(find(&e, EV_ABS, ABS_RX), 180 * GYRO_PER_DEG);
        assert_eq!(find(&e, EV_ABS, ABS_RZ), -512);
        assert_eq!(find(&e, EV_MSC, MSC_TIMESTAMP), 5_000_000_123u64 as u32 as i32);
    }

    #[test]
    fn a_sample_without_motion_is_no_events() {
        assert!(motion_events(&MotionSample { pressure: Some(101.3), ..Default::default() }).is_empty());
    }

    #[test]
    fn buttons_map_to_keys() {
        let spec = Spec::buttons("iPhone Buttons", &[DeviceKey::VolumeUp, DeviceKey::Camera, DeviceKey::Action]);
        assert_eq!(spec.keys, vec![KEY_VOLUMEUP, KEY_CAMERA, KEY_PROG1]);
    }
}

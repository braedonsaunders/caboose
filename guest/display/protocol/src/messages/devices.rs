//! The phone's hardware as the computer's devices (docs/devices.md): what the phone
//! offers (`devices`), what it captures (`device.*` client messages) and what the
//! computer asks of it (`device.*` server messages).

use super::{enum_field, Size};
use crate::cbor::Value;
use crate::fields::{self, Fields, MapBuilder};
use crate::ProtocolError;

string_enum!(
    /// What a device is.
    DeviceKind {
        Camera => "camera",
        Depth => "depth",
        Microphone => "microphone",
        Motion => "motion",
        Gamepad => "gamepad",
        Buttons => "buttons",
        Battery => "battery",
    }
);
string_enum!(CameraPosition { Back => "back", Front => "front", External => "external" });
string_enum!(MotionSensor {
    Accelerometer => "accelerometer",
    Gyroscope => "gyroscope",
    Magnetometer => "magnetometer",
    Rotation => "rotation",
    Pressure => "pressure",
});
string_enum!(DeviceKey { VolumeUp => "volume-up", VolumeDown => "volume-down", Camera => "camera", Action => "action" });
string_enum!(ThermalState { Nominal => "nominal", Fair => "fair", Serious => "serious", Critical => "critical" });

/// The most devices one `devices` message offers.
pub const MAX_DEVICES: usize = 32;
/// The most samples one `device.motion` carries.
pub const MAX_MOTION_SAMPLES: usize = 64;

/// A gamepad's `buttons` bits.
pub mod gamepad_buttons {
    pub const SOUTH: u32 = 1 << 0;
    pub const EAST: u32 = 1 << 1;
    pub const WEST: u32 = 1 << 2;
    pub const NORTH: u32 = 1 << 3;
    pub const LEFT_SHOULDER: u32 = 1 << 4;
    pub const RIGHT_SHOULDER: u32 = 1 << 5;
    pub const VIEW: u32 = 1 << 6;
    pub const MENU: u32 = 1 << 7;
    pub const HOME: u32 = 1 << 8;
    pub const LEFT_STICK: u32 = 1 << 9;
    pub const RIGHT_STICK: u32 = 1 << 10;
    pub const DPAD_UP: u32 = 1 << 11;
    pub const DPAD_DOWN: u32 = 1 << 12;
    pub const DPAD_LEFT: u32 = 1 << 13;
    pub const DPAD_RIGHT: u32 = 1 << 14;
}

/// One device in `devices`. Fields beyond `id`, `kind` and `name` are present for the kinds
/// that have them.
#[derive(Debug, Clone, PartialEq)]
pub struct Device {
    /// `^[a-z0-9-]{1,32}$`, stable for the same hardware across connections.
    pub id: String,
    pub kind: DeviceKind,
    /// What Linux shows, 1–64 characters.
    pub name: String,
    pub position: Option<CameraPosition>,
    pub size: Option<Size>,
    pub fps: Option<f64>,
    pub sensors: Option<Vec<MotionSensor>>,
    pub rumble: Option<bool>,
    pub keys: Option<Vec<DeviceKey>>,
}

impl Device {
    /// A device with only its identity; the kind-specific fields absent.
    pub fn new(id: &str, kind: DeviceKind, name: &str) -> Self {
        Self {
            id: id.into(),
            kind,
            name: name.into(),
            position: None,
            size: None,
            fps: None,
            sensors: None,
            rumble: None,
            keys: None,
        }
    }

    /// Whether `id` has the contract's form.
    pub fn valid_id(id: &str) -> bool {
        (1..=32).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
    }

    pub(crate) fn to_value(&self) -> Value {
        MapBuilder::new()
            .put("id", self.id.as_str())
            .put("kind", self.kind)
            .put("name", self.name.as_str())
            .opt("position", self.position)
            .opt("size", self.size)
            .opt("fps", self.fps)
            .opt("sensors", self.sensors.as_ref().map(|s| Value::Array(s.iter().map(|&s| s.into()).collect())))
            .opt("rumble", self.rumble)
            .opt("keys", self.keys.as_ref().map(|k| Value::Array(k.iter().map(|&k| k.into()).collect())))
            .build()
    }

    /// `Ok(None)` for a kind this build does not know, which the caller skips.
    pub(crate) fn from_value(v: &Value) -> Result<Option<Self>, ProtocolError> {
        let f = Fields::new("devices.devices", v)?;
        let Some(kind) = DeviceKind::parse(&f.string("kind")?) else { return Ok(None) };
        Ok(Some(Self {
            id: f.string("id")?,
            kind,
            name: f.string("name")?,
            position: f.opt("position", |v| match v {
                Value::Text(s) => CameraPosition::parse(s),
                _ => None,
            })?,
            size: f.opt_size("size")?,
            fps: f.opt_f64("fps")?,
            // Lists skip names this build does not know, so a newer phone's list still parses.
            sensors: f.opt("sensors", |v| Some(known(fields::as_array(v)?, MotionSensor::parse)))?,
            rumble: f.opt_bool("rumble")?,
            keys: f.opt("keys", |v| Some(known(fields::as_array(v)?, DeviceKey::parse)))?,
        }))
    }
}

fn known<T>(values: &[Value], parse: fn(&str) -> Option<T>) -> Vec<T> {
    values
        .iter()
        .filter_map(|v| match v {
            Value::Text(s) => parse(s),
            _ => None,
        })
        .collect()
}

/// `device.camera` (0xB1): one H.264 access unit, Annex-B.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceCamera {
    pub device: String,
    pub seq: u64,
    pub keyframe: bool,
    pub t_us: u64,
    pub data: Vec<u8>,
}

/// `device.depth` (0xB2): `size.w × size.h` little-endian u16 millimetres.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceDepth {
    pub device: String,
    pub t_us: u64,
    pub size: Size,
    pub data: Vec<u8>,
}

/// `device.audio` (0xB3): one 20 ms Opus packet, 48 kHz mono.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceAudio {
    pub device: String,
    pub t_us: u64,
    pub data: Vec<u8>,
}

/// One reading in `device.motion`, in the phone's portrait axes and Linux's conventions.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct MotionSample {
    pub t_us: u64,
    /// m/s², gravity included; face up reads `z = +9.81`.
    pub accel: Option<[f64; 3]>,
    /// rad/s.
    pub gyro: Option<[f64; 3]>,
    /// µT.
    pub magnet: Option<[f64; 3]>,
    /// Attitude quaternion `[x, y, z, w]`.
    pub rotation: Option<[f64; 4]>,
    /// kPa.
    pub pressure: Option<f64>,
}

impl MotionSample {
    fn to_value(&self) -> Value {
        MapBuilder::new()
            .put("t_us", self.t_us)
            .opt("accel", self.accel.map(|a| floats(&a)))
            .opt("gyro", self.gyro.map(|a| floats(&a)))
            .opt("magnet", self.magnet.map(|a| floats(&a)))
            .opt("rotation", self.rotation.map(|a| floats(&a)))
            .opt("pressure", self.pressure)
            .build()
    }

    fn from_value(v: &Value) -> Result<Self, ProtocolError> {
        let f = Fields::new("device.motion.samples", v)?;
        Ok(Self {
            t_us: f.u64("t_us")?,
            accel: f.opt("accel", as_floats::<3>)?,
            gyro: f.opt("gyro", as_floats::<3>)?,
            magnet: f.opt("magnet", as_floats::<3>)?,
            rotation: f.opt("rotation", as_floats::<4>)?,
            pressure: f.opt_f64("pressure")?,
        })
    }
}

/// `device.motion` (0xB4).
#[derive(Debug, Clone, PartialEq)]
pub struct DeviceMotion {
    pub device: String,
    pub samples: Vec<MotionSample>,
}

/// `device.gamepad` (0xB5): the whole state.
#[derive(Debug, Clone, PartialEq)]
pub struct DeviceGamepad {
    pub device: String,
    /// `gamepad_buttons` bits.
    pub buttons: u32,
    /// Left x, left y, right x, right y (−1…1, up and right positive), left and right
    /// trigger (0…1).
    pub axes: [f64; 6],
}

/// `device.battery` (0xB7).
#[derive(Debug, Clone, PartialEq)]
pub struct DeviceBattery {
    pub device: String,
    /// 0…1.
    pub level: f64,
    pub charging: bool,
    pub full: bool,
    pub low_power: bool,
    pub thermal: ThermalState,
}

/// One entry of `device.status`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceState {
    pub id: String,
    /// The Linux nodes or source the device became.
    pub nodes: Vec<String>,
    /// Why it could not be created.
    pub error: Option<String>,
}

/// `device.rumble` (0x63).
#[derive(Debug, Clone, PartialEq)]
pub struct DeviceRumble {
    pub device: String,
    /// 0…1.
    pub strong: f64,
    pub weak: f64,
    /// 0 stops.
    pub ms: u32,
}

fn floats(values: &[f64]) -> Value {
    Value::Array(values.iter().map(|&v| v.into()).collect())
}

fn as_floats<const N: usize>(v: &Value) -> Option<[f64; N]> {
    let items = fields::as_array(v)?;
    if items.len() != N {
        return None;
    }
    let mut out = [0.0; N];
    for (slot, item) in out.iter_mut().zip(items) {
        *slot = fields::as_f64(item)?;
    }
    Some(out)
}

pub(super) fn devices_value(devices: &[Device]) -> Value {
    MapBuilder::new().put("devices", Value::Array(devices.iter().map(Device::to_value).collect())).build()
}

pub(super) fn devices_from(f: &Fields<'_>) -> Result<Vec<Device>, ProtocolError> {
    let mut devices = Vec::new();
    for v in f.array("devices")? {
        if let Some(device) = Device::from_value(v)? {
            devices.push(device);
        }
    }
    Ok(devices)
}

pub(super) fn camera_value(m: &DeviceCamera) -> Value {
    MapBuilder::new()
        .put("device", m.device.as_str())
        .put("seq", m.seq)
        .put("keyframe", m.keyframe)
        .put("t_us", m.t_us)
        .put("data", m.data.clone())
        .build()
}

pub(super) fn camera_from(f: &Fields<'_>) -> Result<DeviceCamera, ProtocolError> {
    Ok(DeviceCamera {
        device: f.string("device")?,
        seq: f.u64("seq")?,
        keyframe: f.bool("keyframe")?,
        t_us: f.u64("t_us")?,
        data: f.bytes("data")?,
    })
}

pub(super) fn depth_value(m: &DeviceDepth) -> Value {
    MapBuilder::new()
        .put("device", m.device.as_str())
        .put("t_us", m.t_us)
        .put("size", m.size)
        .put("data", m.data.clone())
        .build()
}

pub(super) fn depth_from(f: &Fields<'_>) -> Result<DeviceDepth, ProtocolError> {
    Ok(DeviceDepth {
        device: f.string("device")?,
        t_us: f.u64("t_us")?,
        size: f.req("size", fields::as_size)?,
        data: f.bytes("data")?,
    })
}

pub(super) fn audio_value(m: &DeviceAudio) -> Value {
    MapBuilder::new().put("device", m.device.as_str()).put("t_us", m.t_us).put("data", m.data.clone()).build()
}

pub(super) fn audio_from(f: &Fields<'_>) -> Result<DeviceAudio, ProtocolError> {
    Ok(DeviceAudio { device: f.string("device")?, t_us: f.u64("t_us")?, data: f.bytes("data")? })
}

pub(super) fn motion_value(m: &DeviceMotion) -> Value {
    MapBuilder::new()
        .put("device", m.device.as_str())
        .put("samples", Value::Array(m.samples.iter().map(MotionSample::to_value).collect()))
        .build()
}

pub(super) fn motion_from(f: &Fields<'_>) -> Result<DeviceMotion, ProtocolError> {
    Ok(DeviceMotion {
        device: f.string("device")?,
        samples: f.array("samples")?.iter().map(MotionSample::from_value).collect::<Result<_, _>>()?,
    })
}

pub(super) fn gamepad_value(m: &DeviceGamepad) -> Value {
    MapBuilder::new().put("device", m.device.as_str()).put("buttons", m.buttons).put("axes", floats(&m.axes)).build()
}

pub(super) fn gamepad_from(f: &Fields<'_>) -> Result<DeviceGamepad, ProtocolError> {
    Ok(DeviceGamepad { device: f.string("device")?, buttons: f.u32("buttons")?, axes: f.req("axes", as_floats::<6>)? })
}

pub(super) fn button_value(device: &str, key: DeviceKey, pressed: bool) -> Value {
    MapBuilder::new().put("device", device).put("key", key).put("pressed", pressed).build()
}

pub(super) fn button_from(f: &Fields<'_>) -> Result<(String, DeviceKey, bool), ProtocolError> {
    Ok((f.string("device")?, enum_field(f, "key", DeviceKey::parse)?, f.bool("pressed")?))
}

pub(super) fn battery_value(m: &DeviceBattery) -> Value {
    MapBuilder::new()
        .put("device", m.device.as_str())
        .put("level", m.level)
        .put("charging", m.charging)
        .put("full", m.full)
        .put("low_power", m.low_power)
        .put("thermal", m.thermal)
        .build()
}

pub(super) fn battery_from(f: &Fields<'_>) -> Result<DeviceBattery, ProtocolError> {
    Ok(DeviceBattery {
        device: f.string("device")?,
        level: f.f64("level")?,
        charging: f.bool("charging")?,
        full: f.bool("full")?,
        low_power: f.bool("low_power")?,
        thermal: enum_field(f, "thermal", ThermalState::parse)?,
    })
}

pub(super) fn status_value(devices: &[DeviceState]) -> Value {
    MapBuilder::new()
        .put(
            "devices",
            Value::Array(
                devices
                    .iter()
                    .map(|d| {
                        MapBuilder::new()
                            .put("id", d.id.as_str())
                            .put("nodes", d.nodes.clone())
                            .opt("error", d.error.clone())
                            .build()
                    })
                    .collect(),
            ),
        )
        .build()
}

pub(super) fn status_from(f: &Fields<'_>) -> Result<Vec<DeviceState>, ProtocolError> {
    f.array("devices")?
        .iter()
        .map(|v| {
            let d = Fields::new("device.status.devices", v)?;
            Ok(DeviceState { id: d.string("id")?, nodes: d.strings("nodes")?, error: d.opt_string("error")? })
        })
        .collect()
}

pub(super) fn rumble_value(m: &DeviceRumble) -> Value {
    MapBuilder::new()
        .put("device", m.device.as_str())
        .put("strong", m.strong)
        .put("weak", m.weak)
        .put("ms", m.ms)
        .build()
}

pub(super) fn rumble_from(f: &Fields<'_>) -> Result<DeviceRumble, ProtocolError> {
    Ok(DeviceRumble { device: f.string("device")?, strong: f.f64("strong")?, weak: f.f64("weak")?, ms: f.u32("ms")? })
}

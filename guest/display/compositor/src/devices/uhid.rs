//! The motion sensors and the battery as HID devices over UHID, so the kernel's own
//! drivers serve them (docs/devices.md, "Sensors and battery"): a sensor hub whose
//! collections `hid-sensor-hub` hands to `hid-sensor-accel-3d`, `-gyro-3d`, `-magn-3d`,
//! `-rotation` and `-press`, which make IIO devices; and a consumer control with a battery,
//! from which `hid-input` makes a device-scope power supply.
//!
//! The descriptors follow the fields the drivers look up (Linux 6.12,
//! `drivers/iio/common/hid-sensors`): per sensor a feature report with the reporting
//! state and power state as selector arrays and the report interval in milliseconds, and
//! an input report with one 32-bit field per value, whose unit and exponent give IIO its
//! scale.

use super::sys::*;
use caboose_display_protocol::{MotionSample, MotionSensor};
use std::io;
use std::os::fd::{AsRawFd, OwnedFd};
use std::path::Path;

pub const UHID: &str = "/dev/uhid";

// ---- HID report descriptors ----

/// Builds a HID report descriptor from short items.
#[derive(Default)]
pub struct Descriptor(Vec<u8>);

const MAIN: u8 = 0;
const GLOBAL: u8 = 1;
const LOCAL: u8 = 2;

impl Descriptor {
    fn item(&mut self, tag: u8, kind: u8, data: &[u8]) -> &mut Self {
        let size = match data.len() {
            0 => 0,
            1 => 1,
            2 => 2,
            4 => 3,
            n => panic!("a short item has 0, 1, 2 or 4 bytes, not {n}"),
        };
        self.0.push(tag << 4 | kind << 2 | size);
        self.0.extend_from_slice(data);
        self
    }

    /// The fewest bytes that hold `v` as a two's complement number.
    fn signed(v: i32) -> Vec<u8> {
        if let Ok(b) = i8::try_from(v) {
            vec![b as u8]
        } else if let Ok(h) = i16::try_from(v) {
            h.to_le_bytes().to_vec()
        } else {
            v.to_le_bytes().to_vec()
        }
    }

    fn unsigned(v: u32) -> Vec<u8> {
        if v <= 0xff {
            vec![v as u8]
        } else if v <= 0xffff {
            (v as u16).to_le_bytes().to_vec()
        } else {
            v.to_le_bytes().to_vec()
        }
    }

    pub fn usage_page(&mut self, page: u16) -> &mut Self {
        self.item(0x0, GLOBAL, &Self::unsigned(page as u32))
    }
    pub fn usage(&mut self, usage: u16) -> &mut Self {
        self.item(0x0, LOCAL, &Self::unsigned(usage as u32))
    }
    pub fn logical(&mut self, min: i32, max: i32) -> &mut Self {
        self.item(0x1, GLOBAL, &Self::signed(min));
        self.item(0x2, GLOBAL, &Self::signed(max))
    }
    pub fn unit(&mut self, unit: u32) -> &mut Self {
        self.item(0x6, GLOBAL, &Self::unsigned(unit))
    }
    /// A signed 4-bit exponent, as the HID specification writes it (−3 is `0x0D`).
    pub fn unit_exponent(&mut self, exponent: i8) -> &mut Self {
        self.item(0x5, GLOBAL, &[(exponent as u8) & 0x0f])
    }
    pub fn size(&mut self, bits: u8, count: u8) -> &mut Self {
        self.item(0x7, GLOBAL, &[bits]);
        self.item(0x9, GLOBAL, &[count])
    }
    pub fn report_id(&mut self, id: u8) -> &mut Self {
        self.item(0x8, GLOBAL, &[id])
    }
    pub fn collection(&mut self, kind: u8) -> &mut Self {
        self.item(0xA, MAIN, &[kind])
    }
    pub fn end(&mut self) -> &mut Self {
        self.item(0xC, MAIN, &[])
    }
    pub fn input(&mut self, flags: u8) -> &mut Self {
        self.item(0x8, MAIN, &[flags])
    }
    pub fn feature(&mut self, flags: u8) -> &mut Self {
        self.item(0xB, MAIN, &[flags])
    }
    #[cfg(test)]
    pub fn bytes(&self) -> &[u8] {
        &self.0
    }
}

const APPLICATION: u8 = 0x01;
const LOGICAL: u8 = 0x02;
/// Data, Variable, Absolute.
const VARIABLE: u8 = 0x02;
/// Data, Array, Absolute.
const ARRAY: u8 = 0x00;
/// Constant (padding).
const CONSTANT: u8 = 0x01;

const PAGE_SENSOR: u16 = 0x20;
const REPORT_INTERVAL: u16 = 0x030e;
const REPORTING_STATE: u16 = 0x0316;
const POWER_STATE: u16 = 0x0319;
const REPORTING_NO_EVENTS: u16 = 0x0840;
const REPORTING_ALL_EVENTS: u16 = 0x0841;
const POWER_UNDEFINED: u16 = 0x0850;

/// The units the kernel's sensor drivers recognise (`hid-sensor-ids.h`), as the HID parser
/// reads them.
const UNIT_MILLISECOND: u32 = 0x19;
const UNIT_METERS_PER_SEC_SQRD: u32 = 0x11e0;
const UNIT_RADIANS_PER_SECOND: u32 = 0x12f0;
const UNIT_GAUSS: u32 = 0x01e1_f000;
const UNIT_PASCAL: u32 = 0xf1e1;

/// The report interval a sensor starts with and the rate asked for when a driver sets 0.
pub const DEFAULT_INTERVAL_MS: u32 = 10;

/// One sensor of the hub: its HID usage, values and their scale.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SensorKind {
    pub sensor: MotionSensor,
    usage: u16,
    values: &'static [u16],
    /// Fields per value (the quaternion is one field of four).
    count: u8,
    unit: u32,
    exponent: i8,
}

const KINDS: [SensorKind; 5] = [
    SensorKind {
        sensor: MotionSensor::Accelerometer,
        usage: 0x0073,
        values: &[0x0453, 0x0454, 0x0455],
        count: 1,
        unit: UNIT_METERS_PER_SEC_SQRD,
        exponent: -3,
    },
    SensorKind {
        sensor: MotionSensor::Gyroscope,
        usage: 0x0076,
        values: &[0x0457, 0x0458, 0x0459],
        count: 1,
        unit: UNIT_RADIANS_PER_SECOND,
        exponent: -6,
    },
    SensorKind {
        sensor: MotionSensor::Magnetometer,
        usage: 0x0083,
        values: &[0x0485, 0x0486, 0x0487],
        count: 1,
        unit: UNIT_GAUSS,
        exponent: -5,
    },
    SensorKind { sensor: MotionSensor::Rotation, usage: 0x008a, values: &[0x0483], count: 4, unit: 0, exponent: -8 },
    SensorKind {
        sensor: MotionSensor::Pressure,
        usage: 0x0031,
        values: &[0x0431],
        count: 1,
        unit: UNIT_PASCAL,
        exponent: -2,
    },
];

impl SensorKind {
    /// The raw 32-bit values of a sample for this sensor, in the descriptor's scale.
    pub fn raw(&self, sample: &MotionSample) -> Option<Vec<i32>> {
        let scale = 10f64.powi(-self.exponent as i32);
        let raw = |v: f64| (v * scale).round().clamp(i32::MIN as f64 + 1.0, i32::MAX as f64) as i32;
        Some(match self.sensor {
            MotionSensor::Accelerometer => sample.accel?.iter().map(|&v| raw(v)).collect(),
            MotionSensor::Gyroscope => sample.gyro?.iter().map(|&v| raw(v)).collect(),
            // µT to gauss.
            MotionSensor::Magnetometer => sample.magnet?.iter().map(|&v| raw(v / 100.0)).collect(),
            MotionSensor::Rotation => sample.rotation?.iter().map(|&v| raw(v)).collect(),
            // kPa to pascals.
            MotionSensor::Pressure => vec![raw(sample.pressure? * 1000.0)],
        })
    }
}

/// A sensor's feature report state: what the driver last set.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Feature {
    /// Index + 1 into [no events, all events].
    reporting: u8,
    /// Index + 1 into [undefined, D0 … D4].
    power: u8,
    interval_ms: u32,
}

impl Feature {
    const OFF: Feature = Feature { reporting: 1, power: 6, interval_ms: DEFAULT_INTERVAL_MS };

    fn on(&self) -> bool {
        // All events, full power (D0): what the kernel sets while an application reads.
        self.reporting == 2 && self.power == 2
    }

    fn bytes(&self, id: u8) -> Vec<u8> {
        let mut b = vec![id, self.reporting, self.power];
        b.extend_from_slice(&self.interval_ms.to_le_bytes());
        b
    }

    fn parse(data: &[u8]) -> Option<Self> {
        match data {
            [_, reporting, power, i0, i1, i2, i3, ..] => Some(Self {
                reporting: *reporting,
                power: *power,
                interval_ms: u32::from_le_bytes([*i0, *i1, *i2, *i3]),
            }),
            _ => None,
        }
    }
}

/// The sensor hub's descriptor and state. Report ids are 1 + the sensor's index.
pub struct SensorHub {
    kinds: Vec<SensorKind>,
    features: Vec<Feature>,
    inputs: Vec<Vec<u8>>,
}

impl SensorHub {
    pub fn new(sensors: &[MotionSensor]) -> Self {
        let kinds: Vec<SensorKind> =
            KINDS.iter().filter(|k| sensors.contains(&k.sensor)).copied().collect();
        let inputs = kinds
            .iter()
            .enumerate()
            .map(|(i, k)| {
                let mut b = vec![i as u8 + 1];
                b.resize(1 + 4 * k.values.len() * k.count as usize, 0);
                b
            })
            .collect();
        Self { features: vec![Feature::OFF; kinds.len()], kinds, inputs }
    }

    pub fn sensors(&self) -> Vec<MotionSensor> {
        self.kinds.iter().map(|k| k.sensor).collect()
    }

    pub fn descriptor(&self) -> Vec<u8> {
        let mut d = Descriptor::default();
        for (i, k) in self.kinds.iter().enumerate() {
            d.usage_page(PAGE_SENSOR).usage(k.usage).collection(APPLICATION).report_id(i as u8 + 1);
            // Reporting state: no events or all events.
            d.usage(REPORTING_STATE).logical(1, 2).size(8, 1).collection(LOGICAL);
            d.usage(REPORTING_NO_EVENTS).usage(REPORTING_ALL_EVENTS).feature(ARRAY).end();
            // Power state: undefined, D0 full power … D4 off.
            d.usage(POWER_STATE).logical(1, 6).size(8, 1).collection(LOGICAL);
            for usage in POWER_UNDEFINED..=POWER_UNDEFINED + 5 {
                d.usage(usage);
            }
            d.feature(ARRAY).end();
            d.usage(REPORT_INTERVAL).logical(0, i32::MAX).size(32, 1).unit(UNIT_MILLISECOND).unit_exponent(0);
            d.feature(VARIABLE);
            d.logical(-i32::MAX, i32::MAX).size(32, k.count).unit(k.unit).unit_exponent(k.exponent);
            for &v in k.values {
                d.usage(v).input(VARIABLE);
            }
            d.end();
        }
        d.0
    }

    /// The input report for a sample, if it has this sensor's values; also kept for a
    /// driver that asks for the report.
    pub fn input_report(&mut self, sensor: MotionSensor, sample: &MotionSample) -> Option<Vec<u8>> {
        let i = self.kinds.iter().position(|k| k.sensor == sensor)?;
        let values = self.kinds[i].raw(sample)?;
        let mut b = vec![i as u8 + 1];
        for v in values {
            b.extend_from_slice(&v.to_le_bytes());
        }
        self.inputs[i] = b.clone();
        Some(b)
    }

    /// Whether a sensor is on (a driver powered it and asked for its events).
    pub fn on(&self, sensor: MotionSensor) -> bool {
        self.kinds.iter().position(|k| k.sensor == sensor).is_some_and(|i| self.features[i].on())
    }

    /// The fastest rate a powered sensor asks for, or `None` when every sensor is off.
    pub fn demand_hz(&self) -> Option<f64> {
        self.features
            .iter()
            .filter(|f| f.on())
            .map(|f| 1000.0 / (if f.interval_ms == 0 { DEFAULT_INTERVAL_MS } else { f.interval_ms }) as f64)
            .reduce(f64::max)
    }

    /// Answers `GET_REPORT`: the report's bytes, report id first.
    pub fn get_report(&self, rtype: u8, rnum: u8) -> Option<Vec<u8>> {
        let i = (rnum as usize).checked_sub(1).filter(|&i| i < self.kinds.len())?;
        match rtype {
            UHID_FEATURE_REPORT => Some(self.features[i].bytes(rnum)),
            UHID_INPUT_REPORT => Some(self.inputs[i].clone()),
            _ => None,
        }
    }

    /// Applies `SET_REPORT`; false for a report the hub does not have.
    pub fn set_report(&mut self, rtype: u8, rnum: u8, data: &[u8]) -> bool {
        let Some(i) = (rnum as usize).checked_sub(1).filter(|&i| i < self.kinds.len()) else { return false };
        if rtype != UHID_FEATURE_REPORT {
            return false;
        }
        match Feature::parse(data) {
            Some(f) => {
                self.features[i] = f;
                true
            }
            None => false,
        }
    }
}

/// The battery device: a consumer control (hid-input registers a power supply only on a
/// device with an input) with the battery's state of charge and charging flag. The mute
/// key it declares is never pressed.
pub mod battery {
    use super::*;

    pub fn descriptor() -> Vec<u8> {
        let mut d = Descriptor::default();
        d.usage_page(0x0c).usage(0x01).collection(APPLICATION).report_id(1);
        // Absolute state of charge, first after the report id: hid-input reads it there
        // when it queries the battery.
        d.usage_page(0x85).usage(0x65).logical(0, 100).size(8, 1).input(VARIABLE);
        d.usage_page(0x0c).usage(0xe2).logical(0, 1).size(1, 1).input(VARIABLE);
        d.usage_page(0x85).usage(0x44).logical(0, 1).size(1, 1).input(VARIABLE);
        d.size(6, 1).input(CONSTANT);
        d.end();
        d.0
    }

    /// The input report for a level (0…1) and charging flag. Level 0 reads as 1%: the
    /// kernel ignores a zero report.
    pub fn report(level: f64, charging: bool) -> Vec<u8> {
        let percent = (level.clamp(0.0, 1.0) * 100.0).round().max(1.0) as u8;
        vec![1, percent, if charging { 0b10 } else { 0 }]
    }
}

// ---- /dev/uhid ----

const EVENT_SIZE: usize = 4376;
const UHID_DESTROY: u32 = 1;
const UHID_START: u32 = 2;
const UHID_STOP: u32 = 3;
const UHID_OPEN: u32 = 4;
const UHID_CLOSE: u32 = 5;
const UHID_OUTPUT: u32 = 6;
const UHID_GET_REPORT: u32 = 9;
const UHID_GET_REPORT_REPLY: u32 = 10;
const UHID_CREATE2: u32 = 11;
const UHID_INPUT2: u32 = 12;
const UHID_SET_REPORT: u32 = 13;
const UHID_SET_REPORT_REPLY: u32 = 14;
pub const UHID_FEATURE_REPORT: u8 = 0;
pub const UHID_INPUT_REPORT: u8 = 2;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    Start,
    Stop,
    Open,
    Close,
    Output,
    GetReport { id: u32, rnum: u8, rtype: u8 },
    SetReport { id: u32, rnum: u8, rtype: u8, data: Vec<u8> },
}

/// Parses one event the kernel wrote (`struct uhid_event`, packed).
pub fn parse_event(b: &[u8]) -> Option<Event> {
    let u32_at = |o: usize| Some(u32::from_ne_bytes(b.get(o..o + 4)?.try_into().ok()?));
    let u16_at = |o: usize| Some(u16::from_ne_bytes(b.get(o..o + 2)?.try_into().ok()?));
    Some(match u32_at(0)? {
        UHID_START => Event::Start,
        UHID_STOP => Event::Stop,
        UHID_OPEN => Event::Open,
        UHID_CLOSE => Event::Close,
        UHID_OUTPUT => Event::Output,
        UHID_GET_REPORT => Event::GetReport { id: u32_at(4)?, rnum: *b.get(8)?, rtype: *b.get(9)? },
        UHID_SET_REPORT => {
            let size = (u16_at(10)? as usize).min(4096);
            Event::SetReport { id: u32_at(4)?, rnum: *b.get(8)?, rtype: *b.get(9)?, data: b.get(12..12 + size)?.to_vec() }
        }
        _ => return None,
    })
}

fn create2(name: &str, uniq: &str, descriptor: &[u8]) -> Vec<u8> {
    let mut e = vec![0u8; EVENT_SIZE];
    e[0..4].copy_from_slice(&UHID_CREATE2.to_ne_bytes());
    e[4..132].copy_from_slice(&c_field::<128>(name));
    e[132..196].copy_from_slice(&c_field::<64>("caboose/phone"));
    e[196..260].copy_from_slice(&c_field::<64>(uniq));
    e[260..262].copy_from_slice(&(descriptor.len() as u16).to_ne_bytes());
    e[262..264].copy_from_slice(&BUS_VIRTUAL.to_ne_bytes());
    // Vendor, product, version and country stay 0: these are not products of any vendor.
    e[280..280 + descriptor.len()].copy_from_slice(descriptor);
    e
}

fn input2(data: &[u8]) -> Vec<u8> {
    let mut e = vec![0u8; EVENT_SIZE];
    e[0..4].copy_from_slice(&UHID_INPUT2.to_ne_bytes());
    e[4..6].copy_from_slice(&(data.len() as u16).to_ne_bytes());
    e[6..6 + data.len()].copy_from_slice(data);
    e
}

fn get_reply(id: u32, data: Option<&[u8]>) -> Vec<u8> {
    let mut e = vec![0u8; EVENT_SIZE];
    e[0..4].copy_from_slice(&UHID_GET_REPORT_REPLY.to_ne_bytes());
    e[4..8].copy_from_slice(&id.to_ne_bytes());
    match data {
        Some(d) => {
            e[10..12].copy_from_slice(&(d.len() as u16).to_ne_bytes());
            e[12..12 + d.len()].copy_from_slice(d);
        }
        None => e[8..10].copy_from_slice(&(libc::EIO as u16).to_ne_bytes()),
    }
    e
}

fn set_reply(id: u32, ok: bool) -> Vec<u8> {
    let mut e = vec![0u8; EVENT_SIZE];
    e[0..4].copy_from_slice(&UHID_SET_REPORT_REPLY.to_ne_bytes());
    e[4..8].copy_from_slice(&id.to_ne_bytes());
    if !ok {
        e[8..10].copy_from_slice(&(libc::EIO as u16).to_ne_bytes());
    }
    e
}

/// A HID device made through `/dev/uhid`; destroyed when dropped.
pub struct Device {
    fd: OwnedFd,
}

impl Device {
    pub fn create(name: &str, uniq: &str, descriptor: &[u8]) -> io::Result<Self> {
        let fd = open_rw(Path::new(UHID), true)?;
        write_all(&fd, &create2(name, uniq, descriptor))?;
        Ok(Self { fd })
    }

    pub fn raw_fd(&self) -> i32 {
        self.fd.as_raw_fd()
    }

    /// The next event the kernel has queued, if any.
    pub fn next_event(&self) -> io::Result<Option<Event>> {
        let mut buf = vec![0u8; EVENT_SIZE];
        loop {
            match read_some(&self.fd, &mut buf)? {
                None | Some(0) => return Ok(None),
                Some(n) => {
                    if let Some(e) = parse_event(&buf[..n]) {
                        return Ok(Some(e));
                    }
                }
            }
        }
    }

    pub fn input(&self, report: &[u8]) -> io::Result<()> {
        write_all(&self.fd, &input2(report))
    }

    pub fn reply_get(&self, id: u32, data: Option<&[u8]>) -> io::Result<()> {
        write_all(&self.fd, &get_reply(id, data))
    }

    pub fn reply_set(&self, id: u32, ok: bool) -> io::Result<()> {
        write_all(&self.fd, &set_reply(id, ok))
    }
}

impl Drop for Device {
    fn drop(&mut self) {
        let mut e = vec![0u8; EVENT_SIZE];
        e[0..4].copy_from_slice(&UHID_DESTROY.to_ne_bytes());
        let _ = write_all(&self.fd, &e);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn items_use_the_shortest_encoding() {
        let mut d = Descriptor::default();
        d.usage_page(0x20).usage(0x0316).logical(-2147483647, 2147483647).unit(0x19).unit_exponent(-3).size(32, 4);
        assert_eq!(
            d.bytes(),
            &[
                0x05, 0x20, // Usage Page (Sensor)
                0x0a, 0x16, 0x03, // Usage (0x0316)
                0x17, 0x01, 0x00, 0x00, 0x80, // Logical Minimum (−2147483647)
                0x27, 0xff, 0xff, 0xff, 0x7f, // Logical Maximum (2147483647)
                0x65, 0x19, // Unit (milliseconds, as the kernel reads it)
                0x55, 0x0d, // Unit Exponent (−3)
                0x75, 0x20, 0x95, 0x04, // Report Size (32), Report Count (4)
            ]
        );
    }

    #[test]
    fn logical_maximum_255_is_not_read_as_negative() {
        let mut d = Descriptor::default();
        d.logical(0, 255);
        assert_eq!(d.bytes(), &[0x15, 0x00, 0x26, 0xff, 0x00]);
    }

    #[test]
    fn an_accelerometer_collection_has_the_fields_the_driver_looks_up() {
        let hub = SensorHub::new(&[MotionSensor::Accelerometer]);
        let d = hub.descriptor();
        let expected: &[u8] = &[
            0x05, 0x20, 0x09, 0x73, 0xa1, 0x01, 0x85, 0x01, // Sensor, Accelerometer 3D, Application, Report 1
            0x0a, 0x16, 0x03, 0x15, 0x01, 0x25, 0x02, 0x75, 0x08, 0x95, 0x01, 0xa1, 0x02, // Reporting state
            0x0a, 0x40, 0x08, 0x0a, 0x41, 0x08, 0xb1, 0x00, 0xc0, // no events, all events: Feature (Array)
            0x0a, 0x19, 0x03, 0x15, 0x01, 0x25, 0x06, 0x75, 0x08, 0x95, 0x01, 0xa1, 0x02, // Power state
            0x0a, 0x50, 0x08, 0x0a, 0x51, 0x08, 0x0a, 0x52, 0x08, 0x0a, 0x53, 0x08, 0x0a, 0x54, 0x08, 0x0a, 0x55, 0x08,
            0xb1, 0x00, 0xc0, // Feature (Array)
            0x0a, 0x0e, 0x03, 0x15, 0x00, 0x27, 0xff, 0xff, 0xff, 0x7f, 0x75, 0x20, 0x95, 0x01, 0x65, 0x19, 0x55,
            0x00, 0xb1, 0x02, // Report interval (ms): Feature (Variable)
            0x17, 0x01, 0x00, 0x00, 0x80, 0x27, 0xff, 0xff, 0xff, 0x7f, 0x75, 0x20, 0x95, 0x01, 0x66, 0xe0, 0x11,
            0x55, 0x0d, // 32-bit, m/s², 10^−3
            0x0a, 0x53, 0x04, 0x81, 0x02, 0x0a, 0x54, 0x04, 0x81, 0x02, 0x0a, 0x55, 0x04, 0x81, 0x02, // X, Y, Z
            0xc0,
        ];
        assert_eq!(d, expected);
    }

    #[test]
    fn samples_are_scaled_into_their_reports() {
        let mut hub = SensorHub::new(&[
            MotionSensor::Accelerometer,
            MotionSensor::Gyroscope,
            MotionSensor::Magnetometer,
            MotionSensor::Rotation,
            MotionSensor::Pressure,
        ]);
        let sample = MotionSample {
            t_us: 0,
            accel: Some([0.0, -1.5, 9.80665]),
            gyro: Some([0.000_001, 0.0, -2.0]),
            magnet: Some([21.5, 0.0, -40.0]),
            rotation: Some([0.0, 0.0, std::f64::consts::FRAC_1_SQRT_2, std::f64::consts::FRAC_1_SQRT_2]),
            pressure: Some(101.325),
        };
        let words = |r: Vec<u8>| -> Vec<i32> {
            r[1..].chunks(4).map(|c| i32::from_le_bytes(c.try_into().unwrap())).collect()
        };
        let accel = hub.input_report(MotionSensor::Accelerometer, &sample).unwrap();
        assert_eq!(accel[0], 1);
        assert_eq!(words(accel), vec![0, -1500, 9807]);
        assert_eq!(words(hub.input_report(MotionSensor::Gyroscope, &sample).unwrap()), vec![1, 0, -2_000_000]);
        assert_eq!(words(hub.input_report(MotionSensor::Magnetometer, &sample).unwrap()), vec![21500, 0, -40000]);
        assert_eq!(
            words(hub.input_report(MotionSensor::Rotation, &sample).unwrap()),
            vec![0, 0, 70_710_678, 70_710_678]
        );
        let pressure = hub.input_report(MotionSensor::Pressure, &sample).unwrap();
        assert_eq!(pressure[0], 5);
        assert_eq!(words(pressure), vec![10_132_500]);
        assert_eq!(hub.get_report(UHID_INPUT_REPORT, 5).unwrap()[0], 5, "the last report is kept");
    }

    #[test]
    fn a_sensor_runs_while_the_driver_powers_it() {
        let mut hub = SensorHub::new(&[MotionSensor::Accelerometer, MotionSensor::Gyroscope]);
        assert_eq!(hub.demand_hz(), None);
        assert_eq!(hub.get_report(UHID_FEATURE_REPORT, 1).unwrap(), vec![1, 1, 6, 10, 0, 0, 0]);
        // What hid_sensor_power_state writes to switch it on, then a 20 ms interval.
        assert!(hub.set_report(UHID_FEATURE_REPORT, 2, &[2, 2, 2, 20, 0, 0, 0]));
        assert!(hub.on(MotionSensor::Gyroscope));
        assert!(!hub.on(MotionSensor::Accelerometer));
        assert_eq!(hub.demand_hz(), Some(50.0));
        assert!(hub.set_report(UHID_FEATURE_REPORT, 1, &[1, 2, 2, 0, 0, 0, 0]));
        assert_eq!(hub.demand_hz(), Some(100.0), "an interval of 0 asks for the default rate");
        assert!(hub.set_report(UHID_FEATURE_REPORT, 1, &[1, 1, 6, 0, 0, 0, 0]));
        assert!(hub.set_report(UHID_FEATURE_REPORT, 2, &[2, 1, 6, 20, 0, 0, 0]));
        assert_eq!(hub.demand_hz(), None);
        assert!(!hub.set_report(UHID_FEATURE_REPORT, 3, &[3, 2, 2, 0, 0, 0, 0]), "no third sensor");
    }

    #[test]
    fn battery_reports_put_the_charge_first() {
        assert_eq!(battery::report(0.75, true), vec![1, 75, 0b10]);
        assert_eq!(battery::report(0.0, false), vec![1, 1, 0]);
        let d = battery::descriptor();
        // Report 1: charge (8 bits), mute, charging, 6 bits of padding: 2 bytes after the id.
        assert_eq!(&d[..8], &[0x05, 0x0c, 0x09, 0x01, 0xa1, 0x01, 0x85, 0x01]);
    }

    #[test]
    fn events_parse_from_the_packed_layout() {
        let mut b = vec![0u8; EVENT_SIZE];
        b[0..4].copy_from_slice(&UHID_SET_REPORT.to_ne_bytes());
        b[4..8].copy_from_slice(&7u32.to_ne_bytes());
        b[8] = 2;
        b[9] = UHID_FEATURE_REPORT;
        b[10..12].copy_from_slice(&3u16.to_ne_bytes());
        b[12..15].copy_from_slice(&[2, 2, 2]);
        assert_eq!(
            parse_event(&b),
            Some(Event::SetReport { id: 7, rnum: 2, rtype: UHID_FEATURE_REPORT, data: vec![2, 2, 2] })
        );
        let c = create2("iPhone Sensors", "phone", &[1, 2, 3]);
        assert_eq!(&c[260..264], &[3, 0, 6, 0], "descriptor size 3, bus virtual");
        assert_eq!(&c[280..283], &[1, 2, 3]);
    }
}

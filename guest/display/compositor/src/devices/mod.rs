//! The phone's hardware as the computer's devices (docs/devices.md): the hub that makes
//! a Linux device of each device the phone offers, feeds it what the phone captures, tells
//! the phone when applications use it, and takes the devices down when the phone leaves.
//!
//! The hub runs on its own thread so that device I/O (UHID report requests the kernel
//! waits on, force-feedback uploads, pictures and sound) never holds up the compositor.

mod camera;
mod mic;
mod sys;
mod uhid;
mod uinput;

use caboose_display_protocol::{
    Device, DeviceBattery, DeviceKind, DeviceRumble, DeviceState, Message, MotionSensor,
};
use smithay::reexports::calloop::channel::Sender;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::path::{Path, PathBuf};
use std::sync::{mpsc, Arc};
use std::time::{Duration, Instant};

/// Where the hub finds the display's sound server and keeps its files.
pub struct Config {
    /// The display's PulseAudio (`unix:…`), when it runs.
    pub pulse_server: Option<String>,
    /// A private directory for the microphone's pipe.
    pub state_dir: PathBuf,
    /// `$XDG_RUNTIME_DIR/caboose-devices.json`.
    pub status_file: PathBuf,
}

enum Input {
    Offer(Vec<Device>),
    Phone(Message),
    Disconnected,
    MicRecording(bool),
    Stop,
}

/// Sends to the hub and wakes its poll.
#[derive(Clone)]
struct Inbox {
    tx: mpsc::Sender<Input>,
    wake: Arc<OwnedFd>,
}

impl Inbox {
    fn send(&self, input: Input) {
        if self.tx.send(input).is_ok() {
            let _ = sys::write_all(&*self.wake, &1u64.to_ne_bytes());
        }
    }
}

/// The hub's handle, owned by the compositor. Dropping it takes every device down.
pub struct Hub {
    inbox: Inbox,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Hub {
    pub fn spawn(config: Config, out: Sender<Message>) -> io::Result<Self> {
        // SAFETY: eventfd returns a new descriptor or -1.
        let wake = unsafe { libc::eventfd(0, libc::EFD_CLOEXEC | libc::EFD_NONBLOCK) };
        if wake < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: a new descriptor nothing else owns.
        let wake = Arc::new(unsafe { OwnedFd::from_raw_fd(wake) });
        let (tx, rx) = mpsc::channel();
        let inbox = Inbox { tx, wake: wake.clone() };
        let hub_inbox = inbox.clone();
        let thread = std::thread::Builder::new().name("devices".into()).spawn(move || {
            let mut state = State::new(config, out, hub_inbox, rx, wake);
            state.run();
            state.shutdown();
        })?;
        Ok(Self { inbox, thread: Some(thread) })
    }

    /// The complete set of devices the phone offers now.
    pub fn offer(&self, devices: Vec<Device>) {
        self.inbox.send(Input::Offer(devices));
    }

    /// A device message from the phone.
    pub fn phone(&self, message: Message) {
        self.inbox.send(Input::Phone(message));
    }

    /// The phone's display connection closed.
    pub fn disconnected(&self) {
        self.inbox.send(Input::Disconnected);
    }
}

impl Drop for Hub {
    fn drop(&mut self) {
        self.inbox.send(Input::Stop);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

/// How long the motion device's readers are rechecked after its node is opened or closed.
const RECHECK: Duration = Duration::from_millis(200);
/// Housekeeping while there are devices: rechecks, node lookups, retried removals.
const HOUSEKEEPING: Duration = Duration::from_millis(500);
/// The rate asked for while the motion evdev device is open.
const EVDEV_MOTION_HZ: f64 = 100.0;

enum Linux {
    /// Not created: `Entry::error` says why.
    None,
    Gamepad(uinput::Device),
    Buttons(uinput::Device),
    Motion(Motion),
    Battery(uhid::Device),
    Camera(Camera),
    Microphone(Microphone),
}

struct Motion {
    evdev: Option<uinput::Device>,
    /// inotify watch on the evdev node.
    watch: Option<i32>,
    evdev_open: bool,
    recheck: Option<Instant>,
    sensors: Option<(uhid::Device, uhid::SensorHub)>,
}

struct Camera {
    nr: u32,
    output: camera::Output,
    worker: camera::Worker,
    streaming: bool,
}

struct Microphone {
    // Field order is drop order: the watcher and writer stop before the source unloads.
    _watcher: Option<mic::Watcher>,
    writer: mic::Writer,
    _source: mic::Source,
    recording: bool,
}

struct Entry {
    device: Device,
    linux: Linux,
    error: Option<String>,
    /// The phone currently offers it (false while detached after a disconnect).
    offered: bool,
    /// What the phone was last told: `Some(rate)` after `device.open`.
    opened: Option<f64>,
    /// What the phone said when it could not run the device.
    phone_error: Option<String>,
}

impl Entry {
    /// Whether an application is using the device now.
    fn in_use(&self) -> bool {
        match &self.linux {
            Linux::Camera(c) => c.streaming,
            Linux::Microphone(m) => m.recording,
            _ => false,
        }
    }
}

struct State {
    config: Config,
    out: Sender<Message>,
    inbox: Inbox,
    rx: mpsc::Receiver<Input>,
    wake: Arc<OwnedFd>,
    entries: Vec<Entry>,
    battery: Option<DeviceBattery>,
    inotify: Option<OwnedFd>,
    /// Loopback devices that were open when removed, retried until they can go.
    lingering: Vec<u32>,
    /// When to look up nodes again and resend `device.status` if they changed.
    refresh: Vec<Instant>,
    last_status: Vec<DeviceState>,
    running: bool,
}

fn kernel_error(what: &str, path: &str, e: &io::Error) -> String {
    match e.raw_os_error() {
        Some(libc::ENOENT) | Some(libc::ENODEV) => format!("This computer's kernel has no {what} ({path})"),
        Some(libc::EACCES) | Some(libc::EPERM) => format!("No permission to use {path}"),
        _ => format!("{path}: {e}"),
    }
}

/// Whether any process has `node` open (by its `/proc/*/fd` links).
fn node_open(node: &Path) -> bool {
    let Ok(procs) = std::fs::read_dir("/proc") else { return false };
    for p in procs.flatten() {
        let name = p.file_name();
        if !name.to_string_lossy().bytes().all(|b| b.is_ascii_digit()) {
            continue;
        }
        let Ok(fds) = std::fs::read_dir(p.path().join("fd")) else { continue };
        if fds.flatten().any(|fd| std::fs::read_link(fd.path()).is_ok_and(|t| t == node)) {
            return true;
        }
    }
    false
}

/// The IIO devices the kernel made for the HID device with `uniq`.
fn iio_devices(uniq: &str) -> Vec<String> {
    let mut out = Vec::new();
    let Ok(hids) = std::fs::read_dir("/sys/bus/hid/devices") else { return out };
    for hid in hids.flatten() {
        let uevent = std::fs::read_to_string(hid.path().join("uevent")).unwrap_or_default();
        if !uevent.lines().any(|l| l == format!("HID_UNIQ={uniq}")) {
            continue;
        }
        // hid → HID-SENSOR-2000xx.N.auto → iio:deviceN
        for cell in std::fs::read_dir(hid.path()).into_iter().flatten().flatten() {
            for child in std::fs::read_dir(cell.path()).into_iter().flatten().flatten() {
                let n = child.file_name().to_string_lossy().into_owned();
                if n.starts_with("iio:device") {
                    out.push(n);
                }
            }
        }
    }
    out.sort();
    out
}

fn uniq(device: &Device) -> String {
    format!("caboose-{}", device.id)
}

/// Checks a device against the contract's limits.
fn validate(d: &Device) -> Result<(), String> {
    if !Device::valid_id(&d.id) {
        return Err("invalid device id".into());
    }
    let chars = d.name.chars().count();
    if chars == 0 || chars > 64 || d.name.chars().any(char::is_control) {
        return Err("invalid device name".into());
    }
    if matches!(d.kind, DeviceKind::Camera | DeviceKind::Depth) {
        let size = d.size.ok_or("a camera needs its size")?;
        let fps = d.fps.ok_or("a camera needs its frame rate")?;
        if size.w % 2 != 0 || size.h % 2 != 0 || !(160..=3840).contains(&size.w) || !(120..=2160).contains(&size.h) {
            return Err(format!("unsupported picture size {}x{}", size.w, size.h));
        }
        if !(1.0..=60.0).contains(&fps) {
            return Err(format!("unsupported frame rate {fps}"));
        }
    }
    Ok(())
}

impl State {
    fn new(config: Config, out: Sender<Message>, inbox: Inbox, rx: mpsc::Receiver<Input>, wake: Arc<OwnedFd>) -> Self {
        // SAFETY: inotify_init1 returns a new descriptor or -1.
        let inotify = unsafe { libc::inotify_init1(libc::IN_CLOEXEC | libc::IN_NONBLOCK) };
        let inotify = (inotify >= 0).then(|| unsafe { OwnedFd::from_raw_fd(inotify) });
        Self {
            config,
            out,
            inbox,
            rx,
            wake,
            entries: Vec::new(),
            battery: None,
            inotify,
            lingering: Vec::new(),
            refresh: Vec::new(),
            last_status: Vec::new(),
            running: true,
        }
    }

    fn send(&self, message: Message) {
        let _ = self.out.send(message);
    }

    fn run(&mut self) {
        let mut next_housekeeping = Instant::now() + HOUSEKEEPING;
        while self.running {
            let (mut fds, owners) = self.poll_set();
            let timeout = if self.entries.is_empty() && self.lingering.is_empty() {
                -1
            } else {
                next_housekeeping.saturating_duration_since(Instant::now()).as_millis() as i32
            };
            // SAFETY: `fds` is a valid array of pollfd for its length.
            let n = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, timeout) };
            if n < 0 {
                let e = io::Error::last_os_error();
                if e.kind() != io::ErrorKind::Interrupted {
                    tracing::warn!("devices: poll: {e}");
                    std::thread::sleep(Duration::from_millis(100));
                }
                continue;
            }
            for (pfd, owner) in fds.iter().zip(&owners) {
                if pfd.revents != 0 {
                    self.ready(*owner);
                }
            }
            if Instant::now() >= next_housekeeping {
                self.housekeeping();
                next_housekeeping = Instant::now() + HOUSEKEEPING;
            }
        }
    }

    fn poll_set(&self) -> (Vec<libc::pollfd>, Vec<Owner>) {
        let mut fds = Vec::new();
        let mut owners = Vec::new();
        let mut add = |fd: i32, events: i16, owner: Owner| {
            fds.push(libc::pollfd { fd, events, revents: 0 });
            owners.push(owner);
        };
        add(self.wake.as_raw_fd(), libc::POLLIN, Owner::Wake);
        if let Some(i) = &self.inotify {
            add(i.as_raw_fd(), libc::POLLIN, Owner::Inotify);
        }
        for (i, e) in self.entries.iter().enumerate() {
            match &e.linux {
                Linux::Gamepad(d) => add(d.raw_fd(), libc::POLLIN, Owner::Uinput(i)),
                Linux::Battery(d) => add(d.raw_fd(), libc::POLLIN, Owner::Uhid(i)),
                Linux::Motion(m) => {
                    if let Some((d, _)) = &m.sensors {
                        add(d.raw_fd(), libc::POLLIN, Owner::Uhid(i));
                    }
                }
                Linux::Camera(c) => add(c.output.raw_fd(), libc::POLLPRI, Owner::Video(i)),
                _ => {}
            }
        }
        (fds, owners)
    }

    fn ready(&mut self, owner: Owner) {
        match owner {
            Owner::Wake => {
                let mut buf = [0u8; 8];
                let _ = sys::read_some(&*self.wake, &mut buf);
                while let Ok(input) = self.rx.try_recv() {
                    self.input(input);
                    if !self.running {
                        return;
                    }
                }
            }
            Owner::Inotify => self.inotify_ready(),
            Owner::Uinput(i) => {
                let Some(Entry { linux: Linux::Gamepad(d), device, .. }) = self.entries.get_mut(i) else { return };
                match d.service() {
                    Ok(Some(r)) => {
                        let message = Message::DeviceRumble(DeviceRumble {
                            device: device.id.clone(),
                            strong: r.strong,
                            weak: r.weak,
                            ms: r.ms,
                        });
                        self.send(message);
                    }
                    Ok(None) => {}
                    Err(e) => tracing::debug!("gamepad {}: {e}", device.id),
                }
            }
            Owner::Uhid(i) => self.uhid_ready(i),
            Owner::Video(i) => {
                let Some(Entry { linux: Linux::Camera(c), .. }) = self.entries.get(i) else { return };
                if let Some(count) = c.output.usage() {
                    self.camera_usage(i, count > 0);
                }
            }
        }
    }

    fn input(&mut self, input: Input) {
        match input {
            Input::Offer(devices) => self.offer(devices),
            Input::Phone(message) => self.phone(message),
            Input::Disconnected => self.disconnected(),
            Input::MicRecording(on) => {
                if let Some(i) = self.entries.iter().position(|e| matches!(e.linux, Linux::Microphone(_))) {
                    if let Linux::Microphone(m) = &mut self.entries[i].linux {
                        m.recording = on;
                    }
                    self.usage_changed(i);
                }
            }
            Input::Stop => self.running = false,
        }
    }

    // ---- what the phone offers ----

    fn offer(&mut self, devices: Vec<Device>) {
        let mut seen = Vec::new();
        let mut wanted = Vec::new();
        for d in devices.into_iter().take(caboose_display_protocol::MAX_DEVICES) {
            if seen.contains(&d.id) {
                continue;
            }
            seen.push(d.id.clone());
            wanted.push(d);
        }
        // Withdraw what is no longer offered, or offered differently.
        let (kept, withdrawn): (Vec<Entry>, Vec<Entry>) =
            std::mem::take(&mut self.entries).into_iter().partition(|e| wanted.contains(&e.device));
        self.entries = kept;
        for entry in withdrawn {
            self.retire(entry);
        }
        for d in wanted {
            if let Some(e) = self.entries.iter_mut().find(|e| e.device == d) {
                if !e.offered {
                    e.offered = true;
                    e.phone_error = None;
                    attach(&e.linux);
                }
                continue;
            }
            let entry = self.create(d);
            self.entries.push(entry);
        }
        if let Some(b) = self.battery.clone() {
            self.battery_changed(b);
        }
        // The phone hears what is open now; the rest it learns as applications start.
        for i in 0..self.entries.len() {
            self.entries[i].opened = None;
            self.usage_changed(i);
        }
        self.last_status.clear();
        self.send_status();
        let now = Instant::now();
        self.refresh = vec![now + Duration::from_millis(300), now + Duration::from_secs(1), now + Duration::from_secs(3)];
    }

    fn create(&mut self, device: Device) -> Entry {
        let mut entry =
            Entry { device, linux: Linux::None, error: None, offered: true, opened: None, phone_error: None };
        if let Err(e) = validate(&entry.device) {
            entry.error = Some(e);
            return entry;
        }
        let d = entry.device.clone();
        let made = match d.kind {
            DeviceKind::Gamepad => uinput::Device::create(&uinput::Spec::gamepad(&d.name, d.rumble == Some(true)))
                .map(Linux::Gamepad)
                .map_err(|e| kernel_error("uinput", uinput::UINPUT, &e)),
            DeviceKind::Buttons => {
                let keys = d.keys.clone().unwrap_or_default();
                if keys.is_empty() {
                    Err("no buttons".into())
                } else {
                    uinput::Device::create(&uinput::Spec::buttons(&d.name, &keys))
                        .map(Linux::Buttons)
                        .map_err(|e| kernel_error("uinput", uinput::UINPUT, &e))
                }
            }
            DeviceKind::Battery => uhid::Device::create(&d.name, &uniq(&d), &uhid::battery::descriptor())
                .map(Linux::Battery)
                .map_err(|e| kernel_error("UHID", uhid::UHID, &e)),
            DeviceKind::Motion => self.create_motion(&d, &mut entry.error),
            DeviceKind::Camera => self.create_camera(&d, camera::Format::Yuyv),
            DeviceKind::Depth => self.create_camera(&d, camera::Format::Depth),
            DeviceKind::Microphone => self.create_microphone(&d),
        };
        match made {
            Ok(linux) => entry.linux = linux,
            Err(e) => {
                tracing::info!("device {}: {e}", d.id);
                entry.error = Some(e);
            }
        }
        entry
    }

    fn create_motion(&mut self, d: &Device, error: &mut Option<String>) -> Result<Linux, String> {
        let sensors = d.sensors.clone().unwrap_or_default();
        let evdev = if sensors.iter().any(|s| matches!(s, MotionSensor::Accelerometer | MotionSensor::Gyroscope)) {
            match uinput::Device::create(&uinput::Spec::motion(&d.name)) {
                Ok(dev) => Some(dev),
                Err(e) => {
                    *error = Some(kernel_error("uinput", uinput::UINPUT, &e));
                    None
                }
            }
        } else {
            None
        };
        let sensors = if sensors.is_empty() {
            None
        } else {
            let hub = uhid::SensorHub::new(&sensors);
            match uhid::Device::create(&d.name, &uniq(d), &hub.descriptor()) {
                Ok(dev) => Some((dev, hub)),
                Err(e) => {
                    // The evdev device still serves games; say what is missing.
                    *error = Some(format!("No IIO sensors: {}", kernel_error("UHID", uhid::UHID, &e)));
                    None
                }
            }
        };
        if evdev.is_none() && sensors.is_none() {
            return Err(error.take().unwrap_or_else(|| "no motion sensors".into()));
        }
        let mut motion = Motion { evdev, watch: None, evdev_open: false, recheck: None, sensors };
        self.watch_motion(&mut motion);
        Ok(Linux::Motion(motion))
    }

    fn watch_motion(&self, motion: &mut Motion) {
        let (Some(inotify), Some(evdev)) = (&self.inotify, motion.evdev.as_mut()) else { return };
        if motion.watch.is_some() {
            return;
        }
        let Some(node) = evdev.node() else { return };
        let Ok(path) = std::ffi::CString::new(node.as_os_str().as_encoded_bytes()) else { return };
        let mask = libc::IN_OPEN | libc::IN_CLOSE_WRITE | libc::IN_CLOSE_NOWRITE;
        // SAFETY: a valid inotify descriptor and NUL-terminated path.
        let wd = unsafe { libc::inotify_add_watch(inotify.as_raw_fd(), path.as_ptr(), mask) };
        if wd >= 0 {
            motion.watch = Some(wd);
        }
    }

    fn create_camera(&mut self, d: &Device, format: camera::Format) -> Result<Linux, String> {
        let size = d.size.expect("validated");
        let fps = d.fps.expect("validated").round() as u32;
        let nr = camera::add(&d.name, size).map_err(|e| match e.raw_os_error() {
            Some(libc::ENOENT) | Some(libc::ENODEV) => {
                format!("This computer has no v4l2loopback ({})", camera::CONTROL)
            }
            _ => kernel_error("v4l2loopback", camera::CONTROL, &e),
        })?;
        let made = camera::Output::open(nr, format, size, fps).and_then(|output| {
            let fd = output.try_clone()?;
            let worker = camera::Worker::spawn(d.id.clone(), fd, format, size, fps, self.out.clone())?;
            Ok(Camera { nr, output, worker, streaming: false })
        });
        match made {
            Ok(c) => Ok(Linux::Camera(c)),
            Err(e) => {
                let _ = camera::remove(nr);
                Err(format!("{}: {e}", camera::node(nr).display()))
            }
        }
    }

    fn create_microphone(&mut self, d: &Device) -> Result<Linux, String> {
        let server = self.config.pulse_server.clone().ok_or("This display has no sound server")?;
        let _ = std::fs::create_dir_all(&self.config.state_dir);
        let source = mic::Source::load(&server, &self.config.state_dir, &d.name)?;
        let writer = source.open_writer().and_then(mic::Writer::spawn).map_err(|e| format!("microphone pipe: {e}"))?;
        let inbox = self.inbox.clone();
        let watcher = match mic::Watcher::spawn(&server, move |on| inbox.send(Input::MicRecording(on))) {
            Ok(w) => Some(w),
            Err(e) => {
                tracing::warn!("microphone: cannot watch recorders: {e}");
                None
            }
        };
        Ok(Linux::Microphone(Microphone { _watcher: watcher, writer, _source: source, recording: false }))
    }

    /// Takes a device down; a camera or microphone in use is detached instead and kept
    /// until its last reader stops.
    fn retire(&mut self, mut entry: Entry) {
        if entry.in_use() {
            entry.offered = false;
            detach(&entry.linux);
            self.entries.push(entry);
            return;
        }
        self.destroy(entry);
    }

    fn destroy(&mut self, entry: Entry) {
        if let Linux::Motion(Motion { watch: Some(wd), .. }) = &entry.linux {
            if let Some(i) = &self.inotify {
                // SAFETY: removing a watch this descriptor added.
                unsafe { libc::inotify_rm_watch(i.as_raw_fd(), *wd) };
            }
        }
        let nr = match &entry.linux {
            Linux::Camera(c) => Some(c.nr),
            _ => None,
        };
        // Stops the worker and closes the output before the device is removed.
        drop(entry);
        if let Some(nr) = nr {
            if let Err(e) = camera::remove(nr) {
                tracing::debug!("{}: cannot remove yet: {e}", camera::node(nr).display());
                self.lingering.push(nr);
            }
        }
    }

    fn disconnected(&mut self) {
        self.battery = None;
        let entries = std::mem::take(&mut self.entries);
        for e in entries {
            self.retire(e);
        }
        self.write_status();
    }

    // ---- what the phone sends ----

    fn entry(&self, id: &str) -> Option<usize> {
        self.entries.iter().position(|e| e.device.id == id && e.offered)
    }

    fn phone(&mut self, message: Message) {
        match message {
            Message::DeviceCamera(m) => {
                if let Some(Entry { linux: Linux::Camera(c), .. }) = self.entry(&m.device).map(|i| &self.entries[i]) {
                    let _ = c.worker.tx.send(camera::Input::Unit { data: m.data, keyframe: m.keyframe });
                }
            }
            Message::DeviceDepth(m) => {
                if let Some(Entry { linux: Linux::Camera(c), .. }) = self.entry(&m.device).map(|i| &self.entries[i]) {
                    let _ = c.worker.tx.send(camera::Input::Depth { size: m.size, data: m.data });
                }
            }
            Message::DeviceAudio(m) => {
                if let Some(Entry { linux: Linux::Microphone(mic), .. }) =
                    self.entry(&m.device).map(|i| &self.entries[i])
                {
                    let _ = mic.writer.tx.send(mic::Input::Opus(m.data));
                }
            }
            Message::DeviceMotion(m) => {
                let Some(i) = self.entry(&m.device) else { return };
                let Linux::Motion(motion) = &mut self.entries[i].linux else { return };
                for sample in m.samples.iter().take(caboose_display_protocol::MAX_MOTION_SAMPLES) {
                    if let Some(evdev) = &motion.evdev {
                        if motion.evdev_open {
                            let _ = evdev.emit(&uinput::motion_events(sample));
                        }
                    }
                    if let Some((dev, hub)) = &mut motion.sensors {
                        for sensor in hub.sensors() {
                            if hub.on(sensor) {
                                if let Some(report) = hub.input_report(sensor, sample) {
                                    let _ = dev.input(&report);
                                }
                            }
                        }
                    }
                }
            }
            Message::DeviceGamepad(m) => {
                if let Some(Entry { linux: Linux::Gamepad(d), .. }) = self.entry(&m.device).map(|i| &self.entries[i]) {
                    if let Err(e) = d.emit(&uinput::gamepad_events(m.buttons, &m.axes)) {
                        tracing::debug!("gamepad {}: {e}", m.device);
                    }
                }
            }
            Message::DeviceButton { device, key, pressed } => {
                if let Some(Entry { linux: Linux::Buttons(d), device: desc, .. }) =
                    self.entry(&device).map(|i| &self.entries[i])
                {
                    if desc.keys.as_ref().is_some_and(|k| k.contains(&key)) {
                        let _ = d.press(uinput::key_code(key), pressed);
                    }
                }
            }
            Message::DeviceBattery(b) => self.battery_changed(b),
            Message::DeviceError { device, reason } => {
                if let Some(i) = self.entry(&device) {
                    tracing::info!("device {device}: the phone cannot run it: {reason}");
                    self.entries[i].phone_error = Some(reason.chars().take(200).collect());
                    self.write_status();
                }
            }
            _ => {}
        }
    }

    fn battery_changed(&mut self, b: DeviceBattery) {
        if let Some(Entry { linux: Linux::Battery(d), .. }) = self.entry(&b.device).map(|i| &self.entries[i]) {
            let _ = d.input(&uhid::battery::report(b.level, b.charging));
        }
        self.battery = Some(b);
        self.write_status();
    }

    // ---- what the kernel asks ----

    fn uhid_ready(&mut self, i: usize) {
        let Some(entry) = self.entries.get_mut(i) else { return };
        let battery = self.battery.as_ref().filter(|b| b.device == entry.device.id).cloned();
        let mut motion_changed = false;
        match &mut entry.linux {
            Linux::Motion(Motion { sensors: Some((dev, hub)), .. }) => loop {
                match dev.next_event() {
                    Ok(Some(uhid::Event::GetReport { id, rnum, rtype })) => {
                        let _ = dev.reply_get(id, hub.get_report(rtype, rnum).as_deref());
                    }
                    Ok(Some(uhid::Event::SetReport { id, rnum, rtype, data })) => {
                        let ok = hub.set_report(rtype, rnum, &data);
                        let _ = dev.reply_set(id, ok);
                        motion_changed = true;
                    }
                    Ok(Some(_)) => {}
                    Ok(None) => break,
                    Err(e) => {
                        tracing::debug!("sensors: {e}");
                        break;
                    }
                }
            },
            Linux::Battery(dev) => loop {
                match dev.next_event() {
                    Ok(Some(uhid::Event::GetReport { id, rnum: 1, rtype: uhid::UHID_INPUT_REPORT })) => {
                        let report = battery.as_ref().map(|b| uhid::battery::report(b.level, b.charging));
                        let _ = dev.reply_get(id, report.as_deref());
                    }
                    Ok(Some(uhid::Event::GetReport { id, .. })) => {
                        let _ = dev.reply_get(id, None);
                    }
                    Ok(Some(uhid::Event::SetReport { id, .. })) => {
                        let _ = dev.reply_set(id, false);
                    }
                    Ok(Some(_)) => {}
                    Ok(None) => break,
                    Err(e) => {
                        tracing::debug!("battery: {e}");
                        break;
                    }
                }
            },
            _ => {}
        }
        if motion_changed {
            self.usage_changed(i);
        }
    }

    fn inotify_ready(&mut self) {
        let Some(inotify) = &self.inotify else { return };
        let mut buf = [0u8; 4096];
        let mut touched = Vec::new();
        while let Ok(Some(n)) = sys::read_some(inotify, &mut buf) {
            if n == 0 {
                break;
            }
            let mut at = 0;
            while at + 16 <= n {
                let wd = i32::from_ne_bytes(buf[at..at + 4].try_into().unwrap());
                let len = u32::from_ne_bytes(buf[at + 12..at + 16].try_into().unwrap()) as usize;
                touched.push(wd);
                at += 16 + len;
            }
        }
        let due = Instant::now() + RECHECK;
        for e in &mut self.entries {
            if let Linux::Motion(m) = &mut e.linux {
                if m.watch.is_some_and(|w| touched.contains(&w)) {
                    m.recheck = Some(due);
                }
            }
        }
    }

    fn camera_usage(&mut self, i: usize, streaming: bool) {
        let Linux::Camera(c) = &mut self.entries[i].linux else { return };
        if c.streaming == streaming {
            return;
        }
        c.streaming = streaming;
        let _ = c.worker.tx.send(camera::Input::Streaming(streaming));
        self.usage_changed(i);
    }

    /// Tells the phone what changed in a device's use, and removes a detached device
    /// nothing uses any more.
    fn usage_changed(&mut self, i: usize) {
        let entry = &self.entries[i];
        if !entry.offered {
            if !entry.in_use() {
                let entry = self.entries.remove(i);
                self.destroy(entry);
                self.write_status();
            }
            return;
        }
        let want = match &entry.linux {
            Linux::Camera(c) => c.streaming.then_some(None),
            Linux::Microphone(m) => m.recording.then_some(None),
            Linux::Motion(m) => {
                let sensors = m.sensors.as_ref().and_then(|(_, hub)| hub.demand_hz());
                let evdev = m.evdev_open.then_some(EVDEV_MOTION_HZ);
                match (sensors, evdev) {
                    (None, None) => None,
                    (a, b) => Some(Some(a.unwrap_or(0.0).max(b.unwrap_or(0.0)).min(EVDEV_MOTION_HZ))),
                }
            }
            _ => None,
        };
        let device = entry.device.id.clone();
        let was = entry.opened;
        let now = want.map(|rate| rate.unwrap_or(0.0));
        if was == now {
            return;
        }
        self.entries[i].opened = now;
        match want {
            Some(rate) => self.send(Message::DeviceOpen { device, rate_hz: rate }),
            None => self.send(Message::DeviceClose { device }),
        }
        self.write_status();
    }

    fn housekeeping(&mut self) {
        let now = Instant::now();
        // Motion readers: rechecked after inotify saw an open or close, and every few
        // seconds while open (closes by exiting processes are seen this way too).
        for i in 0..self.entries.len() {
            let Linux::Motion(m) = &mut self.entries[i].linux else { continue };
            if m.watch.is_none() && m.evdev.is_some() {
                // The node may have appeared after creation.
                let mut taken = std::mem::replace(
                    m,
                    Motion { evdev: None, watch: None, evdev_open: false, recheck: None, sensors: None },
                );
                self.watch_motion(&mut taken);
                if let Linux::Motion(m) = &mut self.entries[i].linux {
                    *m = taken;
                }
            }
            let Linux::Motion(m) = &mut self.entries[i].linux else { continue };
            let due = m.recheck.is_some_and(|t| t <= now) || (m.evdev_open && m.recheck.is_none());
            if !due {
                continue;
            }
            m.recheck = None;
            let open = m.evdev.as_mut().and_then(|d| d.node()).is_some_and(|n| node_open(&n));
            if open != m.evdev_open {
                m.evdev_open = open;
                self.usage_changed(i);
            }
        }
        self.lingering.retain(|&nr| camera::remove(nr).is_err());
        if self.refresh.first().is_some_and(|t| *t <= now) {
            self.refresh.remove(0);
            self.send_status();
            // A report written while the kernel was still adding the battery is dropped;
            // the charging flag arrives only in reports, so send it again.
            if let Some(b) = self.battery.clone() {
                self.battery_changed(b);
            }
        }
    }

    // ---- status ----

    fn nodes(entry: &mut Entry) -> Vec<String> {
        let uniq = uniq(&entry.device);
        match &mut entry.linux {
            Linux::None => vec![],
            Linux::Gamepad(d) | Linux::Buttons(d) => d.node().map(|n| n.display().to_string()).into_iter().collect(),
            Linux::Motion(m) => {
                let mut nodes: Vec<String> =
                    m.evdev.as_mut().and_then(|d| d.node()).map(|n| n.display().to_string()).into_iter().collect();
                if m.sensors.is_some() {
                    nodes.extend(iio_devices(&uniq));
                }
                nodes
            }
            Linux::Battery(_) => {
                let path = format!("/sys/class/power_supply/hid-{uniq}-battery");
                if Path::new(&path).exists() {
                    vec![path]
                } else {
                    vec![]
                }
            }
            Linux::Camera(c) => vec![camera::node(c.nr).display().to_string()],
            Linux::Microphone(_) => vec![mic::SOURCE.to_owned()],
        }
    }

    fn states(&mut self) -> Vec<DeviceState> {
        let mut out = Vec::new();
        for e in self.entries.iter_mut().filter(|e| e.offered) {
            let nodes = Self::nodes(e);
            out.push(DeviceState { id: e.device.id.clone(), nodes, error: e.error.clone() });
        }
        out
    }

    /// Sends `device.status` when it differs from what the phone last heard.
    fn send_status(&mut self) {
        let states = self.states();
        if states != self.last_status {
            self.last_status = states.clone();
            self.send(Message::DeviceStatus { devices: states });
        }
        self.write_status();
    }

    fn write_status(&mut self) {
        let path = self.config.status_file.clone();
        if self.entries.is_empty() {
            let _ = std::fs::remove_file(&path);
            return;
        }
        let mut devices = Vec::new();
        for i in 0..self.entries.len() {
            let nodes = Self::nodes(&mut self.entries[i]);
            let e = &self.entries[i];
            devices.push(status_json(e, &nodes));
        }
        let battery = self.battery.as_ref().map(|b| {
            format!(
                "{{\"level\": {}, \"charging\": {}, \"full\": {}, \"low_power\": {}, \"thermal\": {}}}",
                b.level.clamp(0.0, 1.0),
                b.charging,
                b.full,
                b.low_power,
                json_string(b.thermal.as_str())
            )
        });
        let updated = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let mut json = format!("{{\"devices\": [{}]", devices.join(", "));
        if let Some(b) = battery {
            json.push_str(&format!(", \"battery\": {b}"));
        }
        json.push_str(&format!(", \"updated\": {updated}}}\n"));
        let tmp = path.with_extension("json.tmp");
        if std::fs::write(&tmp, json).and_then(|_| std::fs::rename(&tmp, &path)).is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
    }

    fn shutdown(&mut self) {
        let entries = std::mem::take(&mut self.entries);
        for e in entries {
            self.destroy(e);
        }
        for nr in std::mem::take(&mut self.lingering) {
            let _ = camera::remove(nr);
        }
        let _ = std::fs::remove_file(&self.config.status_file);
    }
}

#[derive(Clone, Copy)]
enum Owner {
    Wake,
    Inotify,
    Uinput(usize),
    Uhid(usize),
    Video(usize),
}

fn attach(linux: &Linux) {
    if let Linux::Camera(c) = linux {
        let _ = c.worker.tx.send(camera::Input::Attach);
    }
}

fn detach(linux: &Linux) {
    match linux {
        Linux::Camera(c) => {
            let _ = c.worker.tx.send(camera::Input::Detach);
        }
        Linux::Microphone(m) => {
            let _ = m.writer.tx.send(mic::Input::Detach);
        }
        _ => {}
    }
}

fn json_string(s: &str) -> String {
    let mut out = String::from("\"");
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn status_json(e: &Entry, nodes: &[String]) -> String {
    let error = e.error.as_ref().or(e.phone_error.as_ref());
    let mut s = format!(
        "{{\"id\": {}, \"kind\": {}, \"name\": {}, \"nodes\": [{}], \"open\": {}",
        json_string(&e.device.id),
        json_string(e.device.kind.as_str()),
        json_string(&e.device.name),
        nodes.iter().map(|n| json_string(n)).collect::<Vec<_>>().join(", "),
        e.opened.is_some() || e.in_use()
    );
    if let Some(error) = error {
        s.push_str(&format!(", \"error\": {}", json_string(error)));
    }
    s.push('}');
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use caboose_display_protocol::{CameraPosition, Size};

    fn camera(w: i32, h: i32, fps: f64) -> Device {
        Device {
            position: Some(CameraPosition::Back),
            size: Some(Size { w, h }),
            fps: Some(fps),
            ..Device::new("camera-back", DeviceKind::Camera, "iPhone Back Camera")
        }
    }

    #[test]
    fn devices_are_checked_against_the_contract() {
        assert!(validate(&camera(1280, 720, 30.0)).is_ok());
        assert!(validate(&camera(1281, 720, 30.0)).is_err(), "odd width");
        assert!(validate(&camera(1280, 720, 0.0)).is_err());
        assert!(validate(&camera(4096, 2160, 30.0)).is_err());
        let mut depth = camera(256, 192, 15.0);
        depth.kind = DeviceKind::Depth;
        assert!(validate(&depth).is_ok());
        assert!(validate(&Device::new("Bad Id", DeviceKind::Battery, "x")).is_err());
        assert!(validate(&Device::new("battery", DeviceKind::Battery, "")).is_err());
        assert!(validate(&Device::new("battery", DeviceKind::Battery, "iPhone\nBattery")).is_err());
    }

    #[test]
    fn status_json_escapes_and_reports_errors() {
        let e = Entry {
            device: Device::new("camera-back", DeviceKind::Camera, "iPhone \"Back\""),
            linux: Linux::None,
            error: Some("This computer has no v4l2loopback (/dev/v4l2loopback)".into()),
            offered: true,
            opened: None,
            phone_error: None,
        };
        assert_eq!(
            status_json(&e, &[]),
            "{\"id\": \"camera-back\", \"kind\": \"camera\", \"name\": \"iPhone \\\"Back\\\"\", \"nodes\": [], \"open\": false, \"error\": \"This computer has no v4l2loopback (/dev/v4l2loopback)\"}"
        );
    }

    #[test]
    fn kernel_errors_name_what_is_missing() {
        let e = io::Error::from_raw_os_error(libc::ENOENT);
        assert_eq!(kernel_error("uinput", "/dev/uinput", &e), "This computer's kernel has no uinput (/dev/uinput)");
        let e = io::Error::from_raw_os_error(libc::EACCES);
        assert_eq!(kernel_error("UHID", "/dev/uhid", &e), "No permission to use /dev/uhid");
    }
}

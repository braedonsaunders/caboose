# Phone hardware

While Caboose is open and connected, the phone's hardware is the computer's hardware. Its
cameras, depth sensor, microphone, motion sensors, game controllers, buttons and battery
appear in the computer as ordinary Linux devices, served by the kernel's own drivers, so
unmodified Linux applications use them: a browser's video call sees a webcam and a
microphone, a game sees a controller that rumbles and tilts, and `monitor-sensor` reads the
phone's accelerometer.

Nothing here is per application. A device is a standard Linux device node or audio
source, and every program that uses that kind of device finds it.

This document is the contract between the app (`apps/ios/CabooseKit/Sources/CabooseKit/Devices`,
`apps/ios/Caboose/Devices`), the owner's Caboose Display (`guest/display/compositor/src/devices`)
and the guest image (`guest/devices`). The messages travel on the display connection and
are listed with the rest of the protocol in [display.md](display.md#messages). Change it in
the same pull request as any code that changes it.

## What appears

| Phone hardware | iOS source | In the computer | Linux interface |
| --- | --- | --- | --- |
| Back cameras (wide, ultra wide, telephoto) and the front camera | `AVCaptureSession`, H.264 from VideoToolbox | `/dev/videoN`, one per camera, named "iPhone Back Camera", "iPhone Front Camera" … | V4L2 capture device (v4l2loopback), YUYV 4:2:2 |
| LiDAR or TrueDepth | `AVCaptureDepthDataOutput` | `/dev/videoN`, "iPhone Depth" | V4L2 capture device, `Z16` (millimetres) |
| Microphone | `AVAudioEngine` with voice processing, Opus | PulseAudio source `caboose_phone_microphone`, "iPhone Microphone", the default source while present | PulseAudio (and ALSA through it) |
| Accelerometer, gyroscope, magnetometer, attitude, barometer | Core Motion, `CMAltimeter` | IIO devices `accel_3d`, `gyro_3d`, `magn_3d`, `dev_rotation`, `press` | HID sensor hub over UHID: the kernel's `hid-sensor-*` drivers |
| Motion, for games | Core Motion | evdev "iPhone Motion Sensors" (`INPUT_PROP_ACCELEROMETER`) | uinput |
| Controllers: the on-screen controller and controllers paired with the phone | `GameController` | evdev gamepad per controller, rumble (`FF_RUMBLE`) | uinput |
| Buttons: volume up, and volume down or Camera Control, while a camera streams; the Action button | `AVCaptureEventInteraction`, an App Intent | evdev "iPhone Buttons": `KEY_VOLUMEUP`, `KEY_CAMERA`, `KEY_PROG1` | uinput |
| Battery | `UIDevice` | power supply `hid-<uniq>-battery`, a device battery in UPower | HID battery over UHID |
| Thermal state, Low Power Mode | `ProcessInfo` | `$XDG_RUNTIME_DIR/caboose-devices.json` | file |

iOS reports no temperatures: no CPU, battery or ambient temperature reaches an app. The
phone's coarse thermal state (`nominal`, `fair`, `serious`, `critical`) and Low Power Mode
are published in the status file below. The ambient light sensor and proximity sensor have
no public API that leaves the screen on, so they do not appear.

## Kernel support

Each kind of device needs its kernel driver. The computer creates what its kernel
supports and reports the rest to the phone as unavailable (`device.status` below).

| Needs | Kernel | microVM image | Container runtime |
| --- | --- | --- | --- |
| Controllers, motion evdev, buttons | `uinput` | Yes | When the host has `/dev/uinput` |
| Sensors (IIO), battery | `uhid`, `hid-sensor-hub` and the `hid-sensor-*` drivers, `industrialio` | Yes | No |
| Cameras, depth | `videodev`, `v4l2loopback` | Yes (v4l2loopback built with DKMS) | No |
| Microphone | none | Yes | Yes |

The image's kernel is Debian's generic signed kernel (`linux-image-amd64`,
`linux-image-arm64`); Debian's cloud flavour has none of these drivers
([guest/image](../guest/image/README.md)). Every input device made from the phone has the
physical path `caboose/phone`. The image's udev rules give the `caboose` group
`/dev/uinput`, `/dev/uhid` and `/dev/v4l2loopback`, and the event devices with that path
(`guest/devices`).

A container computer shares its host's kernel. When the host has `/dev/uinput`, the host
passes it to new containers, mounts the host's `/dev/input` so the event devices the
computer makes appear inside, and allows input character devices (`c 13:* rmw`); the host
needs `uinput` loaded and `guest/devices/70-caboose-phone-host.rules` installed for the
computer's applications to open them. Devices made through UHID or v4l2loopback would
belong to the host's kernel, outside the container, so a container computer has no IIO
sensors, battery or cameras; they report so in `device.status`. A container created before
its host had `/dev/uinput` gets it when it is created again.

## Consent and lifetime

- **On the phone.** Computer settings has an **iPhone Hardware** section with a switch per
  kind: Cameras and Microphone (off until turned on, and then for that computer only, as
  location is), Motion Sensors, Controllers, Buttons and Battery (on). The phone offers only
  what is switched on and what iOS allows; the system asks for camera and microphone
  access the first time a computer application opens one.
- **Only in the foreground.** The phone offers devices on the owner's display connection,
  which exists only while Caboose is open in the foreground. The agent seat has no devices.
- **On demand.** A camera, the depth sensor, the microphone and the motion sensors run on
  the phone only while a Linux application uses them: the computer sends `device.open` when
  the first application starts streaming and `device.close` when the last one stops. While
  one runs, the app shows which hardware the computer is using, besides iOS's own camera
  and microphone indicators.
- **Disconnect.** When the display connection closes, controllers, motion, buttons, sensors
  and the battery are removed at once. A camera or the microphone that an application is
  still using stays, delivering black pictures or silence, so a call survives switching
  away from Caboose and resumes when the phone returns with the same device id. It is
  removed when no application uses it.
- **Unattended work.** Nothing the computer does without the phone depends on these
  devices. They exist only while the phone is attached.

## Protocol

The client lists `devices: true` in its hello when it can offer devices. The owner's display
lists `devices` in `features` when it accepts them (not with `--no-devices`, and never on
the agent seat). Device messages are ignored from a client without both.

Client → server:

| Type | Name | Fields |
| --- | --- | --- |
| `0xB0` | `devices` | `devices: [device]`: the complete set the phone offers now, replacing the previous set. At most 32 |
| `0xB1` | `device.camera` | `device`, `seq: uint`, `keyframe: bool`, `t_us: uint`, `data: bytes`: one H.264 access unit, Annex-B, with SPS and PPS on keyframes |
| `0xB2` | `device.depth` | `device`, `t_us`, `size: [w, h]`, `data: bytes`: `w × h` little-endian `u16` distances in millimetres, row by row; `0` is no reading |
| `0xB3` | `device.audio` | `device`, `t_us`, `data: bytes`: one 20 ms Opus packet, 48 kHz mono |
| `0xB4` | `device.motion` | `device`, `samples: [sample]`, at most 64 |
| `0xB5` | `device.gamepad` | `device`, `buttons: uint`, `axes: [float]` (exactly 6) |
| `0xB6` | `device.button` | `device`, `key: "volume-up" \| "volume-down" \| "camera" \| "action"`, `pressed: bool`. iOS reports volume down and Camera Control as one button, which the phone sends as `camera` |
| `0xB7` | `device.battery` | `device`, `level: float` (0…1), `charging: bool`, `full: bool`, `low_power: bool`, `thermal: "nominal" \| "fair" \| "serious" \| "critical"` |
| `0xB8` | `device.error` | `device`, `reason: text` (at most 200 UTF-8 bytes): the phone cannot run a device it was asked to open (access denied, camera in use by another app) |

Server → client:

| Type | Name | Fields |
| --- | --- | --- |
| `0x60` | `device.status` | `devices: [{ id, nodes: [text], error?: text }]`: for every offered device, the Linux nodes or source it became (`/dev/video4`, `/dev/input/event7`, `iio:device0`, `caboose_phone_microphone`), and why it, or a part of it, could not be created. Sent after each `devices`, and again as the kernel finishes making nodes |
| `0x61` | `device.open` | `device`, `rate_hz?: float` (motion: the fastest rate an application asked for, sent again when it changes) |
| `0x62` | `device.close` | `device` |
| `0x63` | `device.rumble` | `device`, `strong: float`, `weak: float` (0…1), `ms: uint` (0 stops) |
| `0x64` | `device.keyframe` | `device`: send a camera keyframe next |

A `device` field is a device's `id`. A `device` in `devices`:

```ts
{
  id: string,              // /^[a-z0-9-]{1,32}$/, stable for the same hardware across connections
  kind: "camera" | "depth" | "microphone" | "motion" | "gamepad" | "buttons" | "battery",
  name: string,            // 1–64 characters: what Linux shows ("iPhone Back Camera")
  // camera and depth
  position?: "back" | "front" | "external",
  size?: [w, h],           // the picture size the phone sends: even, 160–3840 by 120–2160
  fps?: number,            // 1–60
  // motion: the sensors the phone has
  sensors?: ("accelerometer" | "gyroscope" | "magnetometer" | "rotation" | "pressure")[],
  // gamepad
  rumble?: boolean,        // the controller can rumble
  // buttons
  keys?: ("volume-up" | "volume-down" | "camera" | "action")[]
}
```

A motion `sample` is `{ t_us, accel?: [x, y, z], gyro?: [x, y, z], magnet?: [x, y, z],
rotation?: [x, y, z, w], pressure?: p }`, each field present when that sensor produced it:
acceleration in m/s² including gravity, by Linux's convention (a phone lying face up reads
`z = +9.81`), angular velocity in rad/s, the calibrated magnetic field in µT, the attitude
quaternion, and pressure in kPa. Axes are the phone's in portrait: `x` to the right, `y`
up the screen, `z` out of the screen. `t_us` everywhere is the phone's monotonic clock in
microseconds; the computer uses it only for intervals.

A gamepad's `buttons` is the pressed set: bit 0 A (south), 1 B (east), 2 X (west), 3 Y
(north), 4 left shoulder, 5 right shoulder, 6 View, 7 Menu, 8 Home, 9 left stick click,
10 right stick click, 11 d-pad up, 12 down, 13 left, 14 right. `axes` is
`[left x, left y, right x, right y, left trigger, right trigger]`: sticks −1…1 with up
and right positive, triggers 0…1. The phone sends a gamepad's state when it changes.

The phone sends `devices` after its hello and whenever the set changes (a controller
connects, a switch changes). It sends `device.battery` once after `devices` and on every
change.

## Computer

`guest/display/compositor/src/devices` creates the devices on the owner's display and
writes `$XDG_RUNTIME_DIR/caboose-devices.json` (atomically replaced, removed when the phone
offers nothing):

```ts
{
  devices: [{ id, kind, name, nodes: string[], error?: string, open: boolean }],
  battery?: { level, charging, full, low_power, thermal },
  updated: number          // ms since the epoch
}
```

### Cameras and depth

Each camera and the depth sensor is a v4l2loopback device the compositor adds through
`/dev/v4l2loopback` (`V4L2LOOPBACK_CTL_ADD`, `exclusive_caps`, the device's name as its
card label) and removes when it is gone and unused. The compositor keeps the device's
output side open with its format set (YUYV at the camera's `size` and `fps`; `Z16` for
depth) and a black picture written, so applications list it as a camera before anything
streams. It subscribes to v4l2loopback's client usage event: the first streaming reader
sends `device.open`, the last one leaving sends `device.close`. Camera access units are
decoded with FFmpeg's H.264 decoder on a worker thread, converted to YUYV and written as
they arrive; a decode error asks for a keyframe. Depth pictures are written as they are.
A camera without pictures for a second repeats its last picture until pictures resume.

### Microphone

The microphone is a `module-pipe-source` in the display's own PulseAudio
(`caboose_phone_microphone`, 48 kHz mono, s16le), made the default source while present.
The compositor decodes each Opus packet and writes it to the pipe through a 60 ms jitter
buffer on a 20 ms clock, writing silence when no packet is due, so applications always
record in real time. It watches the server's source outputs (`pactl subscribe`): the
first one recording from the source sends `device.open`, the last one leaving sends
`device.close`.

### Sensors and battery

The motion sensors are one UHID device, "iPhone Sensors", whose HID report descriptor is a
sensor hub with a collection per sensor the phone has: accelerometer 3D, gyrometer 3D,
compass 3D, device orientation (quaternion) and barometer, as the HID Sensor Usages
specification defines them. The kernel's `hid-sensor-hub` binds it and its `hid-sensor-*`
drivers create the IIO devices, which iio-sensor-proxy (installed in the image) and any IIO
reader use. When a driver powers a sensor on and sets it reporting, the compositor sends
`device.open` with the fastest report interval asked for; when every sensor is off, and the
motion evdev device is closed, `device.close`.

The battery is a second UHID device, "iPhone Battery": a consumer control with the
battery's state of charge and charging flag, from which the kernel makes a device-scope
power supply that UPower shows as the phone's battery. `hid-input` registers a battery only
on a device that also has an input, so it declares a mute key, which is never pressed.

### Input devices

- **Gamepads.** Each gamepad is a uinput device with the phone's name for it and the
  Xbox 360 controller's identity (USB `045e:028e`) and layout, which SDL, Steam and
  browsers map. A, B, X and Y are `BTN_A`, `BTN_B`, `BTN_X` and `BTN_Y` as Linux's xpad
  driver reports them (X, the west button, is `BTN_X`); then `BTN_TL`, `BTN_TR`,
  `BTN_SELECT`, `BTN_START`, `BTN_MODE`, `BTN_THUMBL`, `BTN_THUMBR`; `ABS_X`, `ABS_Y`,
  `ABS_RX`, `ABS_RY` (−32768…32767, down positive), `ABS_Z`, `ABS_RZ` (0…255) and
  `ABS_HAT0X`, `ABS_HAT0Y` for the d-pad. A gamepad with `rumble` takes `FF_RUMBLE`
  effects; playing one sends `device.rumble` for the effect's length.
- **Motion.** "iPhone Motion Sensors" has `INPUT_PROP_ACCELEROMETER`, `ABS_X`/`ABS_Y`/
  `ABS_Z` at 8192 per g and `ABS_RX`/`ABS_RY`/`ABS_RZ` at 1024 per degree per second, and
  `MSC_TIMESTAMP`, as Linux's own controller drivers report motion. While an application
  holds it open (seen with inotify on its node) the compositor asks for 100 Hz.
- **Buttons.** "iPhone Buttons" reports its keys as presses and releases.

## App

- `DeviceCenter` (CabooseKit) owns the session's offered devices: it builds `devices` from
  the switches, the hardware and the connected controllers, starts and stops each source on
  `device.open` and `device.close`, and sends `device.error` when iOS refuses.
- **Cameras.** One `AVCaptureSession` runs the camera that is open; opening another camera
  switches to it. Pictures are encoded by `VTCompressionSession` as real-time H.264
  (Constrained High profile with low-latency rate control, no reordering, a keyframe every
  2 s and on `device.keyframe`) at the
  device's `size` and `fps`, rotated upright for the phone's orientation and letterboxed
  into that size. While a camera streams, `AVCaptureEventInteraction` delivers volume up as
  `volume-up` and its primary button (volume down or Camera Control) as `camera`.
- **Depth** uses the LiDAR camera where the phone has one, otherwise TrueDepth, at the
  depth output's native size.
- **Microphone.** `AVAudioEngine`'s input with voice processing, converted to 48 kHz mono
  and encoded to Opus by AudioToolbox in 20 ms packets. Voice processing cancels the echo
  only of sound the engine itself plays; the computer's sound plays through its own
  renderer, so during a call on the computer with the phone's speaker, the far end hears
  itself. Headphones avoid it.
- **Motion.** `CMMotionManager` device motion (attitude, rotation rate, calibrated magnetic
  field, and acceleration as gravity plus user acceleration) at the asked rate, at most 100 Hz, and `CMAltimeter` pressure,
  batched every 20 ms.
- **Controllers.** Every `GCController` with an extended gamepad profile is a gamepad, and
  so is the on-screen controller when Customize gives other windows **A Linux controller**
  rather than keys (keys are the default).
  `device.rumble` plays through `GCController.haptics`, or Core Haptics for the on-screen
  controller.
- **Action button.** The **Press Computer Action Key** App Intent sends a press and release
  of `action` while Caboose is connected.

## Checks

`guest/display/scripts/check-devices.py`, as root inside a computer whose owner's display
runs, plays a phone over the display protocol: it offers every kind of device, then checks
each through the kernel's own interfaces (evdev, IIO buffers, the power supply, V4L2 with
ffmpeg, PulseAudio with `parec`), that applications starting and stopping send
`device.open` and `device.close`, that a rumble played through evdev arrives as
`device.rumble`, and that disconnecting removes what it should
([guest/display](../guest/display/README.md#build-and-test)). The phone's side is covered by
`DeviceTests` in CabooseKit and the device checks in [apps/ios/README.md](../apps/ios/README.md).

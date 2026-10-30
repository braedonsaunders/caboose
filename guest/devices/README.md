# Phone devices in the guest

What a computer needs for the phone's hardware to become its devices
([docs/devices.md](../../docs/devices.md)). The devices themselves are made by the owner's
Caboose Display ([guest/display](../display/README.md), `compositor/src/devices`); this
component prepares the kernel and the device nodes it uses.

| File | Installed as | What |
| --- | --- | --- |
| `install.sh` | run by the components installer | Installs the rules and module configuration below, adds `caboose` to `video`, and installs `iio-sensor-proxy` and, for the image's kernel, `v4l2loopback-dkms` with the kernel headers DKMS builds it against. A running computer builds v4l2loopback for its own kernel when Debian still publishes that kernel's headers. |
| `70-caboose-devices.rules` | `/etc/udev/rules.d/` | Gives the `caboose` group `/dev/uinput`, `/dev/uhid` and `/dev/v4l2loopback`, and the event devices made from the phone (physical path `caboose/phone`). |
| (generated) | `/etc/modules-load.d/caboose-devices.conf` | Loads `uinput`, `uhid` and `v4l2loopback` at boot. |
| (generated) | `/etc/modprobe.d/caboose-v4l2loopback.conf` | `devices=0`: the display adds a loopback device per camera the phone offers. |

The microVM image uses Debian's generic kernel (`linux-image-amd64`, `linux-image-arm64`),
which has `uinput`, `uhid`, the HID sensor drivers, IIO and V4L2; Debian's cloud kernel has
none of them. Container computers do not receive the host's kernel device nodes or
input directory: those interfaces do not isolate devices between tenants. Only the
private PulseAudio microphone is supported in containers; other phone devices report
unavailability.

## Install

`install.sh MODE` as root, where `MODE` is the components installer's (`image-vm`, `vm`,
`image-container`, `container`); the container modes do nothing. It is part of the guest
components bundle (`guest/components`).

## Test

`guest/display/scripts/check-devices.py` plays a phone against the owner's display on a
computer with this component installed and checks every kind of device; see
[guest/display](../display/README.md#checks).

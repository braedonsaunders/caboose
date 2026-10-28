# Caboose guest image

This image builder and boot check are under development. A successful real boot,
Xpra authentication and memory snapshot restore have not yet been verified. Do
not use the output as a production image until those checks pass.

On x86-64 Linux, install Node 22 or later, npm, git, curl, qemu-utils and
libguestfs tools (`virt-resize`, `virt-customize`, `virt-get-kernel`). The
libguestfs appliance needs a host kernel in `/boot` and access to KVM. For
example, on Ubuntu WSL2 install `linux-image-generic` as well as
`libguestfs-tools qemu-utils isc-dhcp-client`. Nested virtualization must be enabled and
`/dev/kvm` usable. The build downloads packages from Debian, Xpra, Microsoft,
NodeSource and npm; it needs network access and several gigabytes of disk space.

```sh
sudo env OUT_DIR=/absolute/path/to/disks ./build.sh
```

The build creates `base.raw` (24 GiB sparse RAW), `vmlinux` and `initrd`. It
publishes them only after customization succeeds. An existing complete output is
left alone; choose a fresh output directory to rebuild. Boot the resized image
with `root=/dev/vda3 rw` and its matching initrd. AppKit's raw overlay uses
`cp --reflink=auto`: on ext4 without reflinks this copies the disk instead and
uses more space and time.

For the experimental check, install Cloud Hypervisor at
`/usr/local/bin/cloud-hypervisor`, host `xpra`, and `iproute2`, then run:

```sh
sudo env DISKS=/absolute/path/to/disks ./smoke-boot.sh
```

The check creates a temporary TAP and overlay, starts a guest through
`@braedonsaunders/appkit-desk`, configures an isolated test network, starts
Xpra after installing a random token, and attempts to inspect both app windows
via the host Xpra client. It attempts a memory snapshot and restore and removes
its temporary TAP and files on exit. It requires a free `cbsmoke` TAP name and
vsock CID 7910. It does not set up guest internet access. The check is not yet
validated on a complete image.

The upstream agent is taken from Bunkhouse commit
`307f2eee512f27459843a588b38200f57abb6bcf` and the protocol core from
`@braedonsaunders/appkit-desk` 0.6.0. The guest agent runs as root; the
`caboose` account has passwordless sudo, so an authenticated guest user has
full control of its VM. No host or display credentials are baked into the image.

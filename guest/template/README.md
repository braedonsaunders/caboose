# Template guest helper

`caboose-template.py prepare` isolates the dedicated template target and refuses
capture if a non-root process remains. It only runs on a guest whose kernel
command line contains `caboose.template=1 systemd.unit=caboose-template.target`; the image and disk must be a fresh,
disposable copy, without a real computer's data or credentials. The target keeps
the private desk agent and vsock bridge available to the host.

`caboose-template.py refresh-vsock` schedules a virtio-vsock reprobe; the host
reconnects and checks the child CID with `check-vsock CID`.
`caboose-template.py reinitialize MAC CID` is intended to run on a restored
child while the host blocks network traffic. It requires the prepare marker and
no non-root process, checks the guest vsock CID, reprobes virtio-rng to discard snapshot-cached bytes, mixes fresh host-backed
entropy and reseeds the kernel RNG, changes the machine ID and NIC address,
and regenerates SSH host keys. The host schedules `restart-agent`, reconnects,
and checks the new agent process identity to discard copied userspace random
state. After reset succeeds, `caboose-template.py activate` starts the normal multi-user target while the host network remains fenced. A failure
exits nonzero and must keep the VM and network fenced. The host must verify these
operations on its actual guest kernel and Cloud Hypervisor before exposing a
child; the helper does not create or register snapshots.

Syntax check: `python3 -m py_compile guest/template/caboose-template.py`.

A real-host check uses a disposable copy of the published golden image, never a
computer's overlay. On a Linux KVM host, stage `vmlinux` and `initrd`, and make
`base.raw` with `cp --reflink=always` on the same filesystem as the golden base.
Stage this directory and the AppKit desk source tree, with a `package.json`
containing `{"type":"module"}` at the stage root. With a TypeScript runner
installed, run inside a new network namespace:

```sh
sudo unshare -n env TEMPLATE_CHECK_STAGE=/path/to/disposable-stage \
  TEMPLATE_CHECK_GOLDEN=/path/to/golden/base.raw \
  APPKIT_DESK_ENTRY=/path/to/staged-appkit/packages/desk/src/index.ts \
  tsx /path/to/staged/guest/template/check-template.mts
```

The check bootstraps the helper into its disposable disk before a cold boot into
the isolated target. Its test snapshot is never a production template. The
check refuses a disk sharing the golden file's inode or a non-private
network namespace. It starts only disposable VMs and stops them on exit. After
checking that the test VMMs exited, remove the disposable stage. The check
fails closed if the guest's vsock CID does not refresh or the reset fails.

For a short device diagnostic, `TEMPLATE_CHECK_QUICK=1` skips registration and
full image hashing while retaining the disposable-disk and namespace checks.
Use the default mode to verify registration and compatibility as well.

`check-source.mts` exercises the actual host source builder, complete component
version check, registration, a full-hash fork, and rejection of a modified
prepared config. It also tests recovery refusal for an uncommitted TAP ownership
receipt and a held image-root host lock. Stage the host source files used by the
builder, the complete files listed in `guest/components/manifest.json`, and the
built AppKit desk package at `node_modules/@braedonsaunders/appkit-desk` under a
private test root. The root must contain disposable `base.raw`, `vmlinux` and
`initrd`; the base must include the complete current guest bundle. Do not use a
real computer's disk. With the same Linux KVM and private-network precautions,
run:

```sh
sudo unshare -n env TEMPLATE_CHECK_STAGE=/path/to/disposable-stage \
  tsx /path/to/staged/guest/template/check-source.mts
```

This check reads the full image and snapshot files for identity verification.
It creates and keeps test artifacts inside the stage; after verifying the test
VMM has exited, remove the stage. `TEMPLATE_CHECK_RECOVERY_ONLY=1` runs only the
recovery refusal checks in a fresh private stage.

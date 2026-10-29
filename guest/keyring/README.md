# Owner keyring

`caboose-keyring` initializes an empty GNOME Keyring store with a nonempty host-generated
password, or unlocks the existing login collection with that password. It runs as uid 1000
and uses the owner's persistent session bus. It adopts the existing Secret Service through
standard D-Bus activation and sends GNOME’s PAM unlock request to its control socket after verifying the peer PID
against the D-Bus owner. It never starts an unlock subprocess, replaces a daemon, deletes keyrings, changes a password,
or selects a plaintext browser password store. It does not persist the supplied password.

The host supplies 32 random bytes encoded as 64 lowercase hex characters on stdin. One
trailing newline is accepted for a private credential file. Keep that credential in a
mode-0600 file in the computer's private host state and include it in protected backups.
Do not place it in a command argument or environment variable. For an operator bootstrap,
pipe that file into `docker exec -i -u caboose COMPUTER /usr/bin/python3 /opt/caboose/keyring/caboose-keyring`.
Install the helper first; the guest requires `python3-gi` and `gnome-keyring`.

The helper prints only a fixed JSON state: `ready` (exit 0), `migration-required` (exit 3),
or `unavailable` (exit 1). It serializes invocations with a runtime file lock. An unlocked
existing default collection is usable without modification. A locked login/default pair
requires its current password; other existing collections or ambiguous aliases require an
explicit operator migration. A new random password cannot decrypt an old keyring. No
migration or credential reset occurs automatically.

Run `python3 guest/keyring/test_keyring.py` for the creation and preservation policy tests.
Real service checks require Debian 13: initialize an empty disposable home; store a test
secret; repeat the helper and browser launch; freeze/resume; cold restart with the same host
credential; verify the original secret and an unlocked default collection each time. A wrong
credential after cold boot must return `migration-required` and leave stored files intact.
The helper addresses the owner bus only; the agent seat has a separate session bus.

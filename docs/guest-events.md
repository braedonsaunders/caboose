# Guest events

The host opens one bounded `POST /events` long poll to its computer's private Files
service, using that computer's current Files bearer token. The public Files proxy does
not expose event endpoints. Each runtime owns its subscriptions, task IDs, transcript
offsets, receiver generation and cancellation. Freeze, park and deletion stop reception.
Old guests without the endpoint need the guest component update; there is no periodic
exec fallback.

The request contains `session` (32 lowercase hex digits), a nonnegative `generation`,
`cursor`, `channels`, `tasks: [{id, offset, turn}]`, `phone` and `acks`. Task IDs are UUIDs,
offsets are nonnegative safe integers, and at most 256 tasks are admitted. Channels are
`bridge.request`, `bridge.cancel`, `phone`, `notification`, `now-playing`, `media`,
`agent.tick`, `agent.mailbox` and `fs`. Request bodies are bounded to 256 KiB. Responses
contain an opaque cursor and at most 128 `{channel, record, receipt?}` records. The guest
bounds serialized output to 1 MiB; the host independently bounds the body to 2 MiB and
validates envelopes before dispatch. Agent records may occupy 1 MiB; other channel
records are limited to 256 KiB. Each adapter retains its field validators and byte limits.

Queue files remain authoritative until acceptance. The host acknowledges a record in
the next request only after its adapter returns successfully. Receipts bind the queue
name, inode and content digest. A lost response or acknowledgement may replay a record.
Bridge requests move to `claimed` before delivery and stay there until the bridge response
helper retires them. A transport acknowledgement does not remove a claimed bridge request.
This provides at-least-once transport acceptance, not a durable receipt from a phone or
APNs. Existing queue expiry, producer retention and tmpfs cold-boot behavior still apply.

Task subscriptions include only the host's live tasks. Transcript byte offsets advance
through accepted chunks; an incomplete line is bounded to 2 MiB. The mailbox adapter
rechecks the host-owned task/profile binding and turn before durable journal dispatch.
Mailbox response publication and explicit media/state API reads can execute guest
commands; idle observation does not execute them.

Inotify drives queue and state observation. Long polls have a bounded timeout, and
reconnects resynchronize authoritative state. Scoped watches and process descriptors
close when each request ends. Invalid IDs, channels and offsets cannot select arbitrary
paths. The service uses directory descriptors and refuses symlink traversal.

Phone presence uses a separate bounded authenticated `POST /events/presence` renewal
once per second while a foreground phone is connected. Its `{session, generation, phone}`
lease is fenced against stale requests. Renewal is independent of slow mailbox consumers.
The guest's existing `bridge/present` mtime contract remains exactly three seconds;
missing renewals expire naturally. This HTTP renewal spawns no guest process.

The focused tests are `apps/host/src/guest-events.test.ts`,
`apps/host/src/event-adapters.test.ts` and `guest/files/test_events.py`. Runtime timing
requires Linux inotify and isolated synthetic fixtures. No zero-CPU or fixed-latency
claim follows from replacing the exec timers.

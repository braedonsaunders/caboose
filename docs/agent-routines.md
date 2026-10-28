# Host persistent agent routines

`apps/host/src/agent-routines.ts` is a host-owned scheduler, instantiated once for each
computer. It stores definitions and run reservations in a private JSON file in that
computer's state directory. Polling runs in the host without a phone connection. The
host integration supplies the runtime adapter and starts and closes the scheduler with
the computer context. The module does not register HTTP routes.

## Definitions and policies

A definition contains `name` (1–80 characters), `profileId` (canonical UUID), `prompt`
(1–16000 characters), an AppKit `RecurrenceSchedule`, `paused`, `missed`, `overlap`, and
`deliveryGraceMs`. Unknown fields are rejected. There are at most 100 definitions and
100 outstanding run reservations per computer. Schedule validation, timezone calendar
arithmetic, interval anchoring, active periods, DST gaps and folds all come from
`@braedonsaunders/appkit-jobs/recurrence` (published package 0.3.0 or compatible).
Calendar DST gaps are skipped; a fold uses the earlier instant once. A null `nextAt`
means exhausted. Creating or editing a definition initializes its next occurrence
strictly after the current clock, including for one-shot schedules.

- `missed: "skip"` is the default. A polling tick delivers the persisted occurrence up
  to `deliveryGraceMs` late (default 30000, allowed 0–300000 milliseconds). The grace is
  checked again after waking and just before admission. Beyond grace, overdue ticks are
  discarded; an exact-current occurrence remains eligible under AppKit's skip policy.
  Setting grace to zero requires exact-clock delivery and normally skips late polling.
- `missed: "coalesce"` delivers the oldest persisted due instant once and advances the
  cursor strictly beyond now. There is no sequence of catch-up runs. A reserved coalesced
  run can execute arbitrarily late after a host restart or slow wake. Its scheduled
  instant, rather than actual execution time, determines the active-period filter.
- `overlap: "skip"` is the only overlap policy. A reserved or active task blocks a second
  run, including a manual run. Scheduled ticks while blocked advance the cursor and are
  discarded, with no pending catch-up run. Discarded ticks do not create history entries.
- Manual runs use `runNow(id)`. They require an unpaused routine and an available profile,
  do not advance the schedule cursor, and bypass the calendar's active-period filter.
  The method returns a durable reservation; the host's next scheduler tick dispatches it.

Editing or resuming a routine resets the cursor strictly after now and invalidates any
undispatched reservation. Pausing or deleting prevents new admission but does not cancel
an already admitted task. Deletion removes the definition; its active task remains tracked
until terminal. Profile revision changes, missing profiles and archived profiles are
reconciled before schedule evaluation on every tick. They reset the cursor and invalidate
undispatched work. Restoring a profile has no archive backlog. Already admitted tasks
remain resolvable through their stable UUIDs.

## HTTP API

Routes use the same computer/tenant authorization as profile and task APIs and remain
available while the computer is parked. `GET /v1/agent/routines` returns `{ routines, error }`;
`POST` creates a definition and returns `201 { routine }`. `GET/PATCH /:id` read/edit it;
`DELETE /:id` removes it. `POST /:id/run` returns `202 { run }` after durable reservation.
`GET /:id/history` returns that routine's history and `GET /history` returns all retained
runs, both as `{ runs }`. Run ids are the task UUIDs. No public response includes internal
launch snapshots. Control clients receive `agent.routines.changed` after persisted changes.
The production host opens one scheduler in each computer's state directory and starts it
independently of phone connections. It closes the scheduler before retiring the computer.

## Integration contract

```ts
const routines = await AgentRoutines.open(computerStatePath, {
  runtime: {
    snapshot: async (profileId, prompt) => /* RoutineSnapshot | null */,
    acquire: async () => /* wake, acquire existing lease, return release */,
    lookup: async taskId => /* durable restored task status or definitive null */,
    start: async (input, taskId) => /* idempotent task admission */,
  },
  onChange: () => { /* broadcast history/definition invalidation */ },
  onError: error => { /* report scheduler/persistence error */ },
})
routines.start() // serial ticks; default 1000 ms between completed polls
// On host/context shutdown:
await routines.close()
```

`RoutineSnapshot` is `{ revision: string, input: Record<string, unknown> }`. Return null
for a missing or archived profile. `revision` is a stable identifier (at most 256
characters) that changes for every launch-affecting profile edit, including memory,
archive and restore. The root adapter hashes the complete resolved profile snapshot.
The exact JSON `input` is an opaque internal envelope holding the task request and the
resolved profile snapshot. The scheduler persists it with the reservation, bounded to
512000 UTF-8 bytes, and passes the same value on every admission attempt. It never
rebuilds a reserved task from a new profile snapshot.

`acquire` wakes the computer and holds its existing lifecycle lease through lookup and
admission; its returned function releases that lease in every outcome. An admitted
agent task owns its own lease. `lookup` runs only after acquisition and must restore the
guest's durable task records before returning. Null means definitively absent, never
an inaccessible guest, unknown state or a lookup failure. Those failures must throw.
`start` unwraps the envelope and calls `AgentTasks.start(request, { id: taskId,
profile: snapshot })` in the profile-aware host integration. It must resolve the same
UUID idempotently or fail closed when admission/effects are uncertain.

Both task methods return `{ status: "active" | "succeeded" | "failed", detail?: string }`.
Map running and paused tasks to active; map cancelled, failed and uncertain terminal
tasks to failed. In particular uncertain effects must be terminal, never represented as
absence or a request to repeat effects. Diagnostics are bounded to 2000 characters and
shown in history. Task envelopes are omitted from public history results and removed
from terminal records on persistence.

`profileChanged(profileId)` is an awaited fast-path after profile edits, archive,
restore or deletion. The host calls it before acknowledging the mutation. Correctness
does not depend on two-file atomicity: persisted `profileRevision` is compared against
the runtime snapshot on each subsequent tick. A crash after the profile write and before
this hook therefore invalidates work during reconciliation.

Public methods are `list()`, `get(id)`, `create(input)`, `update(id, patch)`, `delete(id)`,
`history(routineId?)`, `runNow(id)`, `profileChanged(profileId)`, `tick()`, `start(pollMs?)`
and `close()`. History is newest first, with at most 100 terminal runs across the computer
plus all outstanding runs. `onChange` fires only after a successful durable commit.
Unchanged active task statuses and repeated identical lookup errors do not write the store.
Use the existing agent input/conflict/not-found errors when mapping API responses.

## Persistence, recovery and lifecycle

The scheduler commits the advanced cursor, stable random task UUID, profile revision and
exact launch envelope in one write **before** waking or admitting a task. The file store
uses a private temporary file, file fsync, rename and directory fsync. In-memory state
changes only after save completes. Any save failure latches that instance closed to
further state changes and dispatch; the host reports the error and reopens the store
after repairing persistence. The file loader rejects stores larger than 64 MB. A failed commit may have reached disk, so reopening reads
and validates the durable state rather than assuming the old version won.

A reserved run is looked up before every admission attempt, including after restart.
If its task exists, the scheduler records that result even when the routine or profile
has subsequently changed. If definitely absent, the scheduler revalidates the routine
revision, pause/deletion, profile revision/availability and delivery grace immediately
before calling `start` with the original UUID and envelope. Lookup or admission failures
leave the reservation outstanding with a diagnostic. A previously active task that is
now definitively missing becomes failed; it is never launched again.

Definitions, cursor changes, manual reservations and dispatch decisions serialize on one
operation chain. Waking and lookup happen outside that chain so an edit can invalidate
work during a slow wake. Final revalidation and admission hold the chain. Concurrent
`tick()` calls share one cycle. `close()` clears the polling timer, prevents new dispatch
and drains accepted operations and the current cycle; it leaves no polling timer behind.
Runtime adapter promises must settle (with adapter-owned I/O timeouts); close waits for
an outstanding wake, lookup or admission rather than abandoning its lease.

The store is single-process: do not open the same per-computer path in multiple scheduler
instances or host processes. Atomic file replacement does not provide a cross-process
lock. Exactly-once effects depend on the task runtime's durable same-UUID admission and
uncertain-effect handling; the scheduler cannot infer the result of an external effect.

## Validation

Run the focused tests with `pnpm --filter caboose-host exec vitest run
src/agent-routines.test.ts --maxWorkers=1 --minWorkers=1`, and host typechecking with
`pnpm --filter caboose-host typecheck`. Tests inject persistence, runtime and clock, and
cover polling grace, skip/coalesce, overlap, profile/routine changes during wake,
restart recovery before/after admission, persistence failures, same-UUID retries,
bounded history, DST/exhaustion, private-file reopening and shutdown without timers.

## Agent tools and durability

A profile task can use the `caboose-agent-tools` MCP server to read its identity,
list, save, update and forget its memories, and list, read, create, edit, pause,
delete, run and inspect the history of its own routines. Routine schedules are the
AppKit JSON union above: the model supplies an IANA timezone and translates the
owner's request to a schedule. It asks for missing timezone information. These tools
cannot change a profile's provider, approvals, or unrelated capabilities.

The host enables the tools only for a task with a host-owned, durable task/profile
binding and a configured dispatcher. The guest stdio server writes bounded UUID
requests to the task's mailbox; the host polls tracked running tasks independently of
turn delivery, verifies the current task and turn, and supplies the bound profile to
its dispatcher. It writes the result to the mailbox over the guest command channel.
The host owner and phone bearer credentials never enter this channel or the guest.
The mailbox is not an isolation boundary among processes running as the shared guest
user: such processes can read and modify mailbox traffic. The host enforces profile
scope and opens mailbox paths without following symlinks. Routine mutations recheck the bound profile inside the scheduler write queue, including after an owner reassigns a routine. Partial memory edits merge omitted fields inside the profile write queue, preserving concurrent owner edits.

Before dispatch, a private host journal fsyncs an intent with the request ID, scope,
and payload fingerprint; a completed result is also persisted. Reusing the same ID
with different content or scope fails. A pending intent after a crash is reported as
uncertain and is not executed again. The caller must inspect current memories or
routines before making a new request. A timeout or closed stdio connection can occur
after the host began an operation, so the result is similarly uncertain. This protects
against repeating the same request ID, not a new ID the caller chooses after a timeout.
On shutdown or before parking, the host pauses task polling, awaits
`AgentTasks.drainToolWork()` and then `AgentToolJournal.drain()` after closing admission.
The journal is single-process, capped at 256 receipts per task, 2000 task bindings and
receipts per computer, and 32 MiB; when full, tools fail rather than discard receipts.
A host restart restores bindings from the private journal, never from guest files.

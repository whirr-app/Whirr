# ADR 0011: A reset is a server-row deletion, and row identity is the evidence

- Status: Accepted
- Date: 2026-09-27

Supersedes one sentence of [ADR 0009](0009-standalone-podcasts-and-private-cloud-state.md): "A
stale playback session cannot overwrite an explicit reset." The rest of ADR 0009 stands.

## Context

A Reset Progress on one device never reached another. Whirr sent the reset as a `PATCH` to zero, so
the other device's next pull saw a near-zero server position over substantial local progress, and
the zero-position guard (SYNC-SPEC.md §4) did what it is for: it kept local and raised a Resolution
Center conflict. The spec let an "explicit reset" through the guard, but Audiobookshelf carries no
such flag, and every timestamp it does carry is written with the server's clock or a client's.
Trusting any of them would let a glitch, a third-party client or a skewed clock wipe a place in an
audiobook.

Stock Audiobookshelf clients reset differently: they delete the progress row. A deleted row cannot
be confused with a zero written to the same row, and the row id that disappears was assigned by the
server itself.

## Decision

1. **A reset deletes the server row.** The outbox resolves the row id (`GET`), deletes it
   (`DELETE /api/me/progress/:id`; a 404 counts as done), then, for a mixed-format item, restores
   the medium the reset did not touch with a field-scoped `PATCH`. Each phase is persisted, so a
   crash after the delete resumes at the restore.
2. **Row identity is the evidence.** Each pull stores the server row id per identity. On a complete
   `/api/me` snapshot the reset is evidenced when that id is gone: no row exists for the identity,
   or no row carries the id and the winning row was created (`startedAt`) after the stored
   `lastUpdate`. Every comparison is between values the same server assigned. A partial snapshot
   is never evidence. A playback start the guard would refuse makes one single-row `GET` to ask the
   same question before its session sync can recreate the row.
3. **Evidence bypasses the guard and the clock, but not unsent work.** An unacknowledged local
   write, a live session or an active offline session still outranks a reset. A near-zero value on
   the same row id remains a conflict. An unfinished transition over a server-acknowledged finish
   is also evidence.
4. **Unsent listening beats a reset on every source, native RSS included.** When a remote RSS
   episode state with a newer explicit epoch meets this device's unsent listening (a pending tick,
   or the episode now playing), the device re-stamps its own state as a new explicit action and
   publishes it. Listening that already reached iCloud still loses to a later reset.

## Consequences

- A reset from any Whirr device, or a stock client's "discard progress", reaches every Whirr
  device with no Resolution Center item.
- A reset can come back when another device was mid-listen. That is the accepted cost: a returned
  reset is visible and costs one tap, while silently lost listening is hard even to notice.
- A late-draining offline reset deletes unconditionally, as the stock clients do.
- Conflicts raised by the old behaviour are cleared by the pull where evidence now exists, and the
  Resolution Center offers "Use server progress for all" for the rest.

# Sync and local-data contract

This is the binding contract for Persistence and SyncEngine. It defines invariants that must survive
schema, sync, playback, download, and account-lifecycle changes. Known deviations are tracked
as release blockers, not evidence that the contract silently changed.

## 1. Scope and invariants

- One credential namespace (`account:<clientUUID>`) and one server user id own the active store.
  The account may hold several addresses for that one server; `account.serverBaseURL` is the
  active address and never the account's identity. Direct account-domain tables
  carry `accountId`; child tables may inherit ownership through a cascading parent. Derived caches
  must document their key and purge path. `coverPaletteRecord` is keyed by textual item id rather
  than account, so the account-removal composition clears the whole disposable palette store and
  its in-memory peers before rebuilding the graph.
- UI reads observed database projections only. Login/server setup and destructive account switching are the documented exceptions.
- `SyncEngine` is the sole post-login API orchestrator. A sync run has a durable id, reason, start time, completion state, and privacy-safe error category.
- Server DTOs are mapped to DB values in SyncEngine. Unknown media kinds/fields are retained only where explicitly needed for forward compatibility; raw server payloads are never stored.
- A database transaction either applies a page plus its cursor/checkpoint or neither. User state plus its outbox operation is likewise atomic.

## 2. Schema concepts

The schema and its migrations provide at least:

| Concept | Required identity/state |
|---|---|
| Account | credential namespace + server user id, active address (`serverBaseURL`), server version, locally generated stable client UUID |
| Account endpoint | account id + normalized URL (unique per account), preferred flag, sort order, added-at, last reached/failed timestamps; every account has at least one row and the active address is always among them |
| Library | server id, media type, name, last seen generation |
| Item | library id + server item id, media kind, minified metadata, soft-deleted flag; the last seen generation is held against the item in its own seen-set, not as a field of the item itself |
| Podcast episode | item id + episode id; present before podcast UI so identities do not change later |
| Media progress | item/episode identity, position, finished state, server timestamp, local monotonic sequence, origin, stable origin key |
| Outbox operation | client UUID, account, entity key, operation kind, coalescing key, payload version, local sequence, attempts, next attempt, state |
| Playback session | stable client UUID, optional server id, item/episode, timestamps, listened delta, closePending/offline state |
| Listening queue | account-scoped dense order of whole audiobook and podcast-episode identities; local only, with no outbox row and no Audiobookshelf sync |
| Download | file identity, destination-relative path, expected/received size, state, hold reason, error |
| Sync run/page | run id, library, reason, page number, generation, timestamps, result/error category |

Migrations are forward-only, transactional, fixture-tested from every previously released schema,
and never silently destroy outbox/session/download ownership data. The committed first-release
schema fixture is the baseline for later migration tests.

## Native podcast CloudKit sync

Opt-in iCloud sync of native RSS podcast state is live in Debug and Release builds (IC3–IC4, on
`main` since 2026-09-25). It uses the private `iCloud.com.remoteconcern.whirr` container through
`CKSyncEngine`, with every field except `schema` encrypted. Consent is device-local and
default-off, so nothing touches CloudKit until the listener enables sync in Settings > Podcasts;
`PodcastDataSettingsReadiness.iCloudSync` is `true`. Under the
[personal-distribution amendment](adr/0009-standalone-podcasts-and-private-cloud-state.md#personal-distribution-amendment-2026-09-24),
Whirr is installed from Xcode only, so both configurations use the CloudKit Development
environment and share one database; no Production schema is deployed. Real episode-state records
therefore exist on users' devices, and a change to record fields or merge rules must stay
compatible with devices running older builds. The standalone no-account runtime was dropped by the
[2026-09-25 scope amendment](adr/0009-standalone-podcasts-and-private-cloud-state.md#scope-amendment-2026-09-25).
The binding design is [ADR 0009](adr/0009-standalone-podcasts-and-private-cloud-state.md), with
ADR 0011 for reset precedence; device evidence is in the IC0 release packet, and the outstanding
physical checks are in the human/device backlog (both private records).

Smart Lists (their rules, shows, hidden episodes, run and download claims) are device-local: they are neither synced through CloudKit nor written to Audiobookshelf, and travel only in the podcast backup file. Server-show references in them are keyed by server user id and item id, so they survive logout and re-login but match nothing under another account.

## 3. Library traversal, pagination, and deletion

ABS does not provide a transactional snapshot cursor. Therefore:

1. A library refresh creates a new local `generation` and requests deterministic server sort by
   stable item id. The implementation currently always sends `sort=id`; the remaining live-wire
   observation is tracked in the human/device backlog. No fallback sort is implemented or implied
   here.
2. Fetch pages sequentially, never concurrently. Deduplicate by server item id across the whole run. Upsert each page transactionally and mark returned rows with the run generation.
3. Stop on the reported total or a short/empty page, with a hard maximum derived from the total plus
   one page. The requested page/limit currently defines the cursor; response page/limit metadata is
   not treated as an authoritative cursor. Any element-level decode diagnostic that drops a
   candidate item identity must mark the run incomplete and disqualify deletion inference: a
   dropped element is indistinguishable from an absent one, so a lossy pass is never evidence of a
   deletion.
4. If the reported total changes, ids repeat across page boundaries, or a page is inconsistent, finish useful upserts but mark the run incomplete and schedule a later backoff refresh. Do not loop immediately.
5. Only a fully successful traversal may infer deletion: rows in that library not seen in the
   completed generation become soft-deleted. "Not seen" includes rows with no seen entry at all —
   items can enter the store from paths that are not traversals, and they must be as eligible for
   deletion as an item some earlier traversal saw, never exempt from it. A second completed traversal still missing them may
   scrub metadata, except rows referenced by progress, outbox, session, download, or listening-queue
   state remain tombstones. The current scrub clears selected display fields rather than every piece
   of metadata.
6. Server `item_removed` sockets are not used. On the first absence from a structurally valid,
   completed library list, soft-delete the library tombstone and run the first item-deletion pass;
   a repeated complete omission may reap unreferenced item metadata on the second pass. Re-listing
   the library clears its tombstone. A lossy library-list decode diagnostic or structural anomaly
   must disqualify this inference, on the same reasoning as the item rule above.

This is a paginated reconciliation, not a synchronous unpaginated launch sweep. Large libraries update page by page and remain browsable throughout.

## 4. Progress clocks and deterministic conflicts

- An acknowledged server `lastUpdate` is authoritative for server state. Preserve it separately from local wall time.
- Each local user mutation receives a database-monotonic `localSequence`; ordering on one device never depends solely on wall clock.
- Offline session timestamps use wall time for the server protocol but are clamped at upload to `min(localTimestamp, observedServerNow + 5 minutes)`. `observedServerNow` comes from the HTTP response `Date` header when available, regardless of whether the configured transport is HTTP or HTTPS. A larger skew is surfaced in local diagnostics and requires confirmation before it can overwrite newer server progress.
- Compare differing origins in this order: unacknowledged local operation by `localSequence`; otherwise server timestamp; then deterministic tie-break `(isFinished, currentTime, stable origin key)`. The account's persisted client UUID is the origin key for local state; server state uses the fixed sentinel `server`. Duplicate server rows that are identical on the preceding fields are semantically equivalent. This identity must never be regenerated on ordinary relaunch, because doing so would change conflict outcomes.
- A server position at or below 5 seconds may not overwrite local progress above both 60 seconds and 2% unless there is reset evidence. Without it, record a `needsResolution` conflict and keep the local value visible.
- Reset evidence is loss of server row identity, never a timestamp. Each pulled row's server `id` is stored per identity. On a successful, complete `/api/me` snapshot (no element dropped by lossy decoding), the reset is evidenced when that stored id is gone: either no row exists for the identity, or no row carries the id and the winning row's `startedAt` is later than the stored `lastUpdate`. Evidence applies the reset without consulting the server clock, but never outranks an unacknowledged local write, a live session, or an active offline session. A near-zero value on the same row id remains a conflict. A playback start the guard would refuse asks the same question of the single row (`GET`) before its session can recreate the server row, and records the conflict when there is no evidence.
- An unfinished transition is also evidence: the local row is finished with that finish acknowledged by the server, and the incoming row is unfinished with a newer `lastUpdate`.
- Finished state is not inferred from `currentTime == duration`; use the server flag/threshold policy. A user reset is an explicit operation and may move backward. It is sent as a deletion of the server row (§5), which is also how stock Audiobookshelf clients reset.
- A server reset never deletes the local progress row: it zeroes the reset medium and keeps `localSequence`, so the stale-tick rule still holds. Applying any pulled field clears an open conflict for that identity.
- Native RSS episode state follows the same precedence. When a remote state with a newer explicit epoch meets this device's unsent listening (a pending tick, or the episode now playing), the device re-stamps its own state as a new explicit action and publishes it. Listening that already reached iCloud still loses to a later reset (ADR 0011, superseding that sentence of ADR 0009).
- A stale background player tick is rejected if its captured local sequence predates the current progress row.
- Ebook position is independent of the audio `currentTime`. `ebookProgress == 1` does not infer `isFinished`, and an ebook-only finish operation must not write `currentTime`.

Regression tests use skewed clocks, equal timestamps, resets, finish/unfinish, stale ticks,
duplicate server progress rows, and zero-position regression cases.

## 5. Outbox lifecycle

States are `pending`, `sending`, `retryWaiting`, `needsResolution`, and `deadLetter`. On launch, stale `sending` rows return to `pending`.

- Entity changes and their outbox rows share one transaction. Every row has a stable client operation UUID and versioned payload.
- Coalesce unsent ordinary progress updates by account + item/episode, retaining the newest position/flags and accumulated unacknowledged listening delta. Never coalesce across a seek/reset boundary, session close, finished/un-finished transition, or different session UUID.
- Drain in local-sequence order per entity/session using an explicit keyed queue. Different entities may use the global request gate concurrently.
- Endpoint-specific acknowledgement is required: ordinary mutations need their documented 2xx; `local-all` requires a matching successful result for each session id. Missing, duplicate, or failed result entries remain queued.
- Transport, 429, and 5xx errors enter exponential `retryWaiting`. 401 uses the one refresh path. A 401 that survives it, including a send the client refuses locally while re-authentication is required, returns the row to `pending` and halts its queue; it never dead-letters. Cancellation returns to pending without increasing attempts.
- Permanent validation/permission/not-found errors do not retry forever. After the first confirmed
  non-retryable response they enter `deadLetter`, retain a privacy-safe reason, and surface a user
  action (discard or refresh metadata). Decode/protocol ambiguity retains the row
  and stops the drain: a `local-all` response that cannot be interpreted at the top level, or whose
  body exceeds the decode bound, says nothing about any submitted session and retains the whole
  batch.
- A local row whose session is confirmed gone, or whose payload is missing, is dead-lettered with a privacy-safe reason; a local read failure retains the row and stops the drain.
- Retry attempts are bounded to one active request per operation UUID. A lost response can cause a
  safe replay only for endpoint/id combinations documented as idempotent. Online session sync adds
  `timeListened` and is not idempotent, so an ambiguous outcome (transport failure or cancellation)
  is reconciled before any replay: the session's own server-side `timeListening` is compared against
  the acknowledged total plus this operation's delta. Already included means the request landed and
  is acknowledged; short by the delta means it did not and is replayed; an unreadable ledger retains
  the row. `currentTime` is never the signal — a backward seek makes it non-monotonic.
- Rows are deleted only after their acknowledgement and a transaction that updates the local authoritative state. Diagnostic history stores category/timing, never payload.
- A reset resolves the row id at send time (`GET`), deletes it (`DELETE /api/me/progress/:id`; 404 counts as done, so a replay is safe), then, for a mixed-format item, restores the other medium's server-captured values with a field-scoped PATCH. The phase and captured values are persisted, so a crash after the delete resumes at the restore without deleting again.

## 6. Playback and offline batch rules

- Online session state is persisted before `/play` is considered active. Sync deltas reset only after acknowledged sync.
- Before background close, atomically write final delta plus `closePending`, then use a bounded background task. Next launch checks pending close/server state before opening a replacement session.
- Offline sessions use stable client UUIDs and bounded `local-all` batches (default 50; lower if live verification finds a server limit). Only matching `success: true` results are cleared.
- If the same session UUID appears twice locally, merge only before either copy is sent; otherwise quarantine it as a data-integrity error.
- Switching items closes or persists closure of the former session before `/play` for the new item on the same device.

## 7. Account removal and data lifecycle

Confirmed logout/server switch performs, in order: stop accepting intents; stop playback;
persist/attempt close; cancel foreground sync and background transfers; invoke server logout; clear
Keychain tokens; remove account DB/files/cache/diagnostics; verify no account-owned rows or files
remain; return to setup. A remote logout failure does not retain local credentials, but it may be
treated as non-blocking only after the local removal has completed. Any thrown pre-cleanup,
credential, purge, deletion, or verification failure remains blocking and retryable, and the app
does not claim logout succeeded. The user is warned that unsynced progress will be destroyed and may
cancel before the sequence begins.

Cancelling foreground sync awaits the engine's in-flight traversal: it stops at its next page
boundary or before its next ancillary hand-off, and removal continues only once it has ended. No
timer bounds the wait; cancellation does.

Adding, removing, reordering, or switching between addresses of the same server is not removal.
A new address is stored only after it answers `GET /status` as Audiobookshelf and `GET /api/me`
through that address with the account's stored access token names the same user id (a password
or API-token login with a matching user id when no tokens exist); a different server or user is
refused without mutation. Switching the active address rebuilds the composition and keeps every
account-owned row, download, queue entry, outbox row, and Keychain item. Removal sweeps the
namespace token item, every endpoint's proxy-header item, and the legacy URL-keyed token item
named in the removal journal, and verifies each is gone.

The production removal coordinator serializes removal as single-flight, quiesces the process
lifetime player/Now Playing/remote commands, gates old-account intents, asynchronously drains
foreground sync through `SyncEngine.shutdown()` before persistence removal, shuts down downloads,
fences token refresh by generation and binds each client to one account, and verifies credential,
custom-header, palette, cache, and account-data sweeps. The cover cache also drains and terminally
rejects cover fetches before its disk root is removed.
Historical gate output is retained in the dated release evidence; current closure requires the
candidate's gates and the named physical-device transfer/relaunch/lock-screen evidence.

Downloads are excluded from backup and purged on logout. The protected database is backed up because it may contain unsynced progress. Cover cache is always disposable: a file store under Caches (`CoverFileStore`) plus the `coverShape` table of measured cover shapes, which account removal deletes and verifies with the other derived rows. Failed deletion is blocking and retryable; the app does not sign another account into a partially-owned store.

The background download adapter never persists tokens separately from Keychain, although a live
URLSession task owns its authorized request. A 401 requests one newly authorized retry request.
Only a definitive rejection becomes visible paused-auth. A transient renewal failure — transport,
429, 5xx, an undecodable response, a 403 — stays an ordinarily retryable transfer failure: that
state is durable and can be cleared only by the user signing in again.

## 8. Regression requirements

- Migration tests, foreign-key checks, and transaction rollback tests.
- Property/model tests for pagination deduplication/termination and conflict determinism.
- Crash-recovery tests at every outbox and account-removal transition, including resumable
  interrupted removal and proof that completion leaves no account-owned rows/files.
- A synthetic 8,000-item sync demonstrating bounded memory, progressive page visibility, no unpaginated request, and no main-actor database work.
- Partial `local-all`, duplicate ids, permanent 4xx, 401 refresh, cancellation, and lost-response scenarios.
- File/database protection and backup-exclusion resource-value tests.

# ADR 0006: Save native podcast episodes to Audiobookshelf

- Status: Accepted — owner decisions OD1–OD10 were taken at the recommended defaults on
  2026-08-31, the server-contract half of the live matrix (runbook Phase A, L1–L12) completed the
  same day on disposable v2.35.1/v2.36.0 instances with no finding that revises a decision, and
  Rhys authorized NP12 implementation on 2026-09-01. The post-implementation Phase B lifecycle
  matrix remains a completion gate and may require this decision to be amended; it is not a
  circular precondition for beginning the implementation that it validates
- Date: 2026-08-31
- Accepted: 2026-09-01

## Context

ADR 0004 makes native RSS subscriptions device-owned and explicitly prohibits
`POST /api/podcasts` and server-side episode-download management until NP12 receives its own ADR
and Rhys's gate. API-CONVENTIONS rule 26 carries the same prohibition.

The NP12 write-contract research (a private record) establishes
that Audiobookshelf v2.35.1 exposes the required create, enqueue, and episode-removal routes, but
also that the old three-task sketch was incomplete. Create/enqueue are admin/root-only; show
creation needs a server folder and absolute contained path; create and enqueue are not atomic;
enqueue success means only
that an in-memory server queue accepted the request; and retry after an uncertain response can
duplicate an episode. The server, rather than Whirr, fetches the enclosure URL. Hard removal is
server-wide, cannot cancel queued work, and does not prove physical bytes were reclaimed.

This ADR authorizes only the bounded implementation below. It does not make the post-implementation
Phase B matrix, final review, device/server evidence, or accessibility evidence complete.

## Decision

Whirr may offer explicit **Save to Audiobookshelf** and post-confirmation
**Remove from Audiobookshelf** actions for one episode from a native RSS subscription, subject to
all of the following boundaries.

### Narrow server-write carve-out

The only newly permitted server-mutation routes are:

1. `POST /api/podcasts`, and only when an eligible destination has no matching server show;
2. `POST /api/podcasts/:id/download-episodes`, with exactly the selected stored RSS episode; and
3. `DELETE /api/podcasts/:id/episode/:episodeId?hard=1`, only for a confirmed, eligible attempt.

No feed check, bulk queue administration, library scan, show edit/delete, deletion of pre-existing
episodes, or auto-download-setting mutation is authorized by this ADR (the last is authorized
separately, by [ADR 0017](0017-edit-server-podcast-automation-settings.md)). `SyncEngine` remains the sole
post-login ABS orchestrator and `ABSApi` remains the sole wire owner.

### Eligibility and authority

- The action is available only when the current server profile reports `admin` or `root` after
  normalization. Audiobookshelf's response remains authoritative; `403` is a permission failure,
  never an offline state.
- The native-subscriptions toggle must be on and the selected episode must still belong to a
  subscribed feed.
- The initial release supports only feeds without a device-held `FeedCredential`. Whirr never
  forwards feed credentials or Keychain values to Audiobookshelf.
- The stored enclosure must be an absolute HTTP(S) URL without embedded credentials. No editable
  URL field is shown.

Whirr already receives the necessary role string: `/api/me.type` is decoded as
`ABSApi.UserProfile.type`, passed into `SyncEngine.ServerAccountProfile.type`, and exposed to
AppModel. The same response carries `permissions.update` and `permissions.delete`, but Whirr
currently discards the permissions object. NP12 decodes only those two optional booleans and adds a
single account-scoped, lifecycle-fenced `ServerPodcastMutationCapability` (the fence itself is new
machinery, specified in the NP12 plan) rather than teaching each card to fetch a profile, reusing
the Settings screen's model, or exposing a general permissions bag.

The capability is action-specific, and — matching the server's own `canUpdate`/`canDelete`
getters — also requires a live `isActive == true` (already decoded on `UserProfile`):

- Save UI requires normalized `admin`/`root` plus `isActive` plus `permissions.update == true`; and
- Remove UI requires normalized `admin`/`root` plus `isActive` plus `permissions.delete == true`.

Audiobookshelf grants update to admins by default but delete only to root by default; an admin can
be granted delete separately. Before a complete live profile proves the relevant capability, after
profile failure, and after logout/account replacement, that mutation UI is absent. A non-admin with
a custom delete permission remains deliberately ineligible. The server still authorizes every
request and its `403` remains final.

### Destination and show identity

Whirr first searches accessible podcast libraries for an exact normalized feed-URL match. One
match is reused. More than one match requires an explicit choice; title is not identity. When no
show matches, the user chooses a podcast library and one of its server-declared folders. Whirr
generates a bounded, sanitized path component from the show title inside that folder; it never
exposes a free-form absolute path.

The create payload is minimal: bounded title and author plus the normalized feed URL. When and only
when Whirr is creating a missing show, it may also include the followed feed's eligible declared
artwork as `imageUrl`; an existing-show enqueue never sends artwork. Missing or rejected artwork is
omitted and cannot block the episode save. Optional rich description remains omitted.

### Operation and truthfulness

The operation is an account-owned, durable state machine. At minimum it distinguishes:

```text
preparing → creatingShow? → requestingDownload → accepted → confirmed
    │            │                  │               │        │
    └────────────┴──────────────────┴───────────────┴────────┼→ failed or uncertain
                                                            └→ deleting → removed
                                                                   └→ deleteFailed / deleteUncertain
```

`accepted` means only that Audiobookshelf returned success from the enqueue route. UI copy says
**Requested on server**. Only a structurally complete expanded podcast response containing the
episode identity may transition to `confirmed` and say **Saved on server**.

A request whose response may have been lost becomes `uncertain`. Whirr does not blindly retry a
create or enqueue request. It reconciles the ordinary server catalogue first and offers a new
explicit attempt only after the server show is found and a complete episode response proves the
episode absent. Queue timing is not a correctness dependency and no fixed poll loop is introduced;
a bounded foreground reconciliation may improve latency, while ordinary refresh supplies eventual
convergence.

The attempt record belongs to the active ABS account even though the RSS episode is device-owned.
It stores stable local feed/episode identity, the server item and episode ids when known, whether a
complete preflight list found the episode absent/present, state, and timestamps; it does not
duplicate credentials or log the enclosure. Account removal deletes attempts. A lifecycle fence — new machinery whose
mechanism the NP12 plan specifies, since no account-generation concept exists in the codebase and
raw account-row identity is reusable — prevents a completion from presenting or writing into a
replacement account.

### Cross-store semantics

Saving copies media to the server; it does not migrate the subscription or change ownership.
Native playback progress, downloads, retention, follow state, and deletion remain independent of
the Audiobookshelf copy. The resulting server episode appears through the existing **On Your
Server** catalogue and follows existing server progress rules.

After `confirmed`, Whirr may offer **Remove from Audiobookshelf** only when a structurally complete
preflight list proved the episode absent before this attempt enqueued it. A pre-existing episode is
never a deletion target. The proof is intentionally conservative but not exclusive—another admin
can race the same download—so removal requires a server-wide confirmation naming the side effects:
the episode disappears for every user and Audiobookshelf removes its progress and playlist
references. `hard=1` attempts to remove the audio file, but because the server continues database
removal after a filesystem error, Whirr says **Removed from Audiobookshelf**, never **storage
freed**.

Removal cannot cancel `accepted`/queued work and never deletes the containing show, even if Whirr
created it and it becomes empty. Toggle-off, logout, cancellation, or app termination stops only
unsent work; it cannot revoke a request which has crossed the network boundary.

### Server-side network trust

The action authorizes Audiobookshelf to fetch the stored feed enclosure and, for a newly-created
show only, eligible declared artwork from the server's network, under the Audiobookshelf
administrator's DNS, redirect, and egress policy. Whirr limits both inputs to values already stored
for the selected subscription, independently rejects malformed/credentialed/non-HTTP and obvious
non-public artwork URLs, and does not provide arbitrary text, feed credentials, cookies, or headers.
Client checks do not pretend to be a complete SSRF defense for another host. The deterministic
SCP.0 matrix on 2026-09-03 additionally proved that the supported v2.35.1 and v2.36.0 servers block
direct, redirected, and rebound private artwork targets while preserving show creation and episode
enqueue; this is a compatibility gate, not a replacement for the administrator's egress policy.

## Reliability rules

- Show creation and episode enqueue are separate resumable steps; documented
  `episodesToDownload` is not used.
- The created server item id is persisted before enqueue begins.
- Cancellation is honored before each send. Once a send begins, an absent response is uncertain.
- Server `4xx` validation/permission errors are terminal for that attempt but do not erase the
  native episode. Transport, `5xx`, malformed success, and cancellation after send remain distinct.
- Reconciliation matches non-empty GUID first when the live wire proves it survives, otherwise
  normalized enclosure/content URL. It never matches by title alone.
- A complete preflight episode list records `preExisting` or `absentBeforeRequest`. Only the latter
  plus a later accepted-and-confirmed server episode id is eligible for removal.
- Delete uses `hard=1`, persists `deleting` before send, and reconciles an absent response. Episode
  absence confirms removal from the library, not physical file deletion. No automatic delete retry.
- The server's process-local queue dedupe is an optimization, not Whirr's idempotency mechanism.
- Logs and diagnostics contain state categories and opaque ids, not credentials, headers, local
  server paths, enclosure URLs, or private feed URLs.

## Consequences if accepted

- ADR 0004 and API-CONVENTIONS rule 26 gain this exact carve-out; their other prohibitions remain.
- `SECURITY.md` records the new server-side egress and credential boundary.
- `ARCHITECTURE.md` records the account-owned cross-store attempt and SyncEngine command path.
- ABSApi gains additive folder/feed/episode identity projections and three endpoint methods.
- Persistence gains one account-owned operation record. Native RSS tables remain device-owned and
  unchanged in ownership.
- A shared session capability hides Save unless admin/root+update and Remove unless
  admin/root+delete; unknown/malformed/unavailable values fail closed and server authorization
  remains final.
- The actions are intentionally unavailable to ordinary users and private/credentialed feeds in
  the first release.

## Rejected alternatives

- **Treat enqueue `200` as saved.** Rejected: the controller returns before transfer or durable
  episode creation.
- **Send `episodesToDownload` while creating the show.** Rejected: v2.35.1 does not consume that
  documented field.
- **Retry automatically after timeout.** Rejected: queue dedupe is temporary and a later duplicate
  can create another file.
- **Forward private-feed credentials.** Rejected: the server downloader has no Whirr credential
  channel, and exporting device-held secrets changes their trust boundary.
- **Let the user type the server path.** Rejected: it leaks filesystem concerns into product UI and
  expands validation/security risk.
- **Download on device and upload bytes.** Rejected: these endpoints accept a URL, not an upload,
  and adding a separate upload protocol is outside NP12.
- **Call removal “Undo Save.”** Rejected: it cannot cancel a queued request, has server-wide side
  effects, and cannot prove physical file deletion or exclusive causation.
- **Clear the show queue or delete the whole show.** Rejected: both exceed the selected episode's
  authority and can affect unrelated work/content.

## Owner decisions

**Resolved:** Rhys took OD1–OD10 at the recommended defaults on 2026-08-31, authorized the
live-server spike (runbook Phase A on disposable instances), and authorized implementation on the
finalized native RSS base on 2026-09-01. The table is retained as the record of what was decided.

| ID | Decision | Accepted decision |
|---|---|---|
| OD1 | Authorize the three-route exception to rule 26 and the server-side egress boundary | Yes, within this ADR only |
| OD2 | Who can see/use NP12 mutations | Save: admin/root + `permissions.update`; Remove: admin/root + `permissions.delete`; server `403` authoritative |
| OD3 | Private feeds in the first release | Ineligible; no credential export |
| OD4 | Destination behavior | Reuse one exact feed match; choose among multiples; choose library/folder only when creating |
| OD5 | Server metadata | Minimal title/author/feed URL; omit artwork and rich description |
| OD6 | User-facing state | Requested after enqueue; Saved only after reconciliation; uncertain is explicit |
| OD7 | Save/removal consequence copy | Save names shared server storage; removal names server-wide episode/progress/playlist effects and never promises storage reclaimed |
| OD8 | Ineligible presentation | Hide each mutation when its role/permission is unknown, unavailable, or false; show disabled with a reason only for an otherwise-eligible credentialed feed |
| OD9 | Removal scope | Only confirmed `absentBeforeRequest` attempts; hard-remove the episode, never queue/show/pre-existing content; reconcile before retry |
| OD10 | Which episode surfaces host Save/Remove | Show-screen episode action menu and episode card action surface only; not swipe actions, the queue sheet, Podcasts-root rows, or the player overflow menu in the first release |

**OD5 amendment accepted 2026-09-03:** a new-show create may additionally carry the followed feed's
eligible declared artwork URL. Missing/rejected artwork is omitted; existing-show enqueue remains
image-free; rich description remains omitted. The prerequisite v2.35.1/v2.36.0 compatibility,
timeout, and server-egress matrix passed with no version disagreement; see the private research
record `scp0-artwork-gate-2026-09-03.json`.

Phase A of the live matrix supplied the wire evidence required to accept this decision. Phase B
remains required before NP12 is complete. If its evidence changes an accepted decision, amend this
ADR and the task/test matrix before merging the affected behavior.

## Amendment 2026-09-07: show-page multi-select Save

The native-feed show page may offer **Save to Audiobookshelf** for a multi-episode selection
(private plan `podcast-server-actions-2026-09-06.md` §3, owner decisions OD1–OD5 taken at
their recommended defaults). The carve-out above is unchanged in every wire-level term:

- The same three routes and no others. A batch is a sequence of the single-episode operation:
  one durable, account-owned attempt per episode and one enqueue request carrying exactly one
  episode. No request ever names more than one episode; `episodesToDownload` stays unused.
- Destination identity is resolved by the existing rule. The first episode of a batch resolves
  (reuse one exact match, prompt for a choice among several, or prompt for a library and folder
  when creating); later episodes pass the established show as `.existing(serverItemID:)`, which
  the resolver still validates against a fresh library search (OD1). A library-and-folder choice
  is handed to at most one episode per batch, so a batch can create at most one show.
- One destination prompt per batch, parametrized by episode count so the sheet states the actual
  consequence (OD3). Cancelling it sends nothing and leaves at most one `preparing` row, exactly
  as the single flow does.
- Cancel is a flag read between episodes; the in-flight episode always completes. No save task is
  cancelled, because a cancellation after the request checkpoint persists `uncertain` for a
  request that may never have reached the wire (OD4).
- The batch stops at the first `uncertain` outcome and at any failure that names shared context
  (destination, permission, account, subscription, credential, transport, server, persistence);
  only a missing source row is a per-episode skip. Stopped work is reported as not attempted,
  never retried.
- Foreground reconciliation of a batch's accepted attempts is grouped per show: one item-detail
  read per tick assesses every attempt, and batch-submitted saves start no schedule of their own
  (OD5). This changes read volume only; the standalone save's schedule is unchanged.
- No batch Remove, no queue administration, no show or policy mutation. Server shows expose no
  Save. The 50-episode ceiling is a client guard, not a server limit.

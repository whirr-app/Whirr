# ADR 0021: The iPhone sends Audiobookshelf books and episodes to the Watch, and lists all it holds

- Status: **Accepted** (2026-11-21, Rhys).
- Date: 2026-11-21
- Extends: [ADR 0019](0019-watch-offline-rss-episodes.md) Decision 2 (the phone owns a desired
  set; the Watch is authoritative about what it holds) and
  [ADR 0020](0020-watch-fetches-rss-episodes-and-reports-status.md) Decisions 6 and 7 (the status
  report, protocol version 1) to Audiobookshelf content. It supersedes nothing.
- Plan: `watch-send-all-plan.md`, revision 3. The owner approved
  its decisions WSA-OD1 to WSA-OD14 on 2026-11-21. Evidence: WRB.0
  (watch-rss-fetch-plan.md §4.2), and the plan's §8 review of
  the source.

## Context

Send to Watch exists only for followed RSS episodes (ADR 0019, ADR 0020). On an Audiobookshelf
show the same row, card and menu have no Watch entry, so the feature appears on one podcast and
not the next.

Audiobookshelf audio already reaches the Watch, but only when the listener starts it on the wrist:

1. The Watch calls `detail()` with its own token.
2. It plans one manifest per audio file.
3. It enqueues the files on its per-account background session, under a Wi-Fi-only default and the
   shared 2 GB budget.

The phone learns almost nothing of this. A completed-titles list exists that no phone code reads,
and only the storage figure counts Audiobookshelf.

WRB.0 showed that a Watch app opened before, but not running, is launched in the background for a
phone request and runs a download without being opened. An Audiobookshelf request adds one step
before the enqueue: the Watch's own `detail()` call. The plan times it in its device pass (WSA.8).

Four facts shape the design:

- **Two writers.** The wrist and the phone can both start and remove Audiobookshelf downloads.
- **Account ownership.** The phone's Audiobookshelf state is account-owned, and logout deletes it
  (SECURITY rule 8). The RSS desired set is device-owned, so ADR 0019 did not face this.
- **Blind status reports.** The phone drops a status report from a signed-out Watch, or from a
  Watch on another account, without keeping anything (`WatchStatusReportAcceptance.swift:17`). It
  cannot tell those apart from a Watch that has never reported.
- **A strict decoder.** The inventory's `Codable` is synthesized, so a new required key would make
  a new phone reject every inventory from an older Watch.

## Decision

1. **The phone keeps a desired set of Audiobookshelf selections, and the Watch downloads them with
   its own sign-in.**
   - A selection is a book or one Audiobookshelf podcast episode (`WatchABSSelection`).
   - The phone publishes the set as `WatchABSSendOffer` over `transferUserInfo`, on a new key,
     `whirr.watch.abs.offer.v1`.
   - The offer carries a generation, per-entry revisions, titles, an optional declared size, an
     explicit `removals` list and the phone's authenticated account stamp.
   - It carries no URL, token or file list. The Watch calls `detail()` and plans exactly as a wrist
     start does.
   - Audiobookshelf audio never crosses the WatchConnectivity link.
2. **No new traffic class and no new credential path.**
   - The Watch makes only the requests a wrist start makes today: `detail()` and the file downloads.
   - They run on the existing per-account background session, under its network policy and the
     shared budget. Only who started them is new.
   - ADR 0004's traffic classes govern RSS and are unaffected.
3. **Every Audiobookshelf download group carries an origin.**
   - A manifest gains `origin` (`watch` or `phone`) and the phone's revision. Existing manifests
     decode as `watch`.
   - The inventory reports every group the Watch holds, from either origin.
4. **Omission removes only what the phone's set owned.**
   - **Phone-origin groups.** A later offer from the same account removes one by omitting it.
   - **Watch-origin groups.** Omission never removes one. Only the offer's `removals` list does,
     and the phone never adopts a Watch-origin group into its set.
   - **Acknowledging a removal.** The phone keeps a selection in `removals` until both of these
     hold:
     - an inventory's `absAcknowledgedGeneration` reaches the generation that first carried it;
     - that inventory no longer lists it.
   - **Tombstones.** A removal the phone asked for leaves none. A phone-origin group removed on
     the Watch leaves a `removed` tombstone, shown as "Removed on Watch".
   - **Playback.** Any removal on the Watch stops playback of that item first.
5. **Both ends fence by account, and the phone's sign-out removes nothing from the Watch.**
   - The Watch ignores an offer whose account stamp is not its own.
   - The inventory stamps its Audiobookshelf half with the Watch's account. The phone applies that
     half only when the stamp matches. Otherwise it shows "Set up Whirr on your Watch" and no
     Audiobookshelf rows.
   - Phone logout deletes the phone's Audiobookshelf rows (SECURITY rule 8) and sends the Watch
     nothing. The Watch keeps what it holds under its own account.
   - After a sign-in, the phone sends no Audiobookshelf offer for that account until it holds an
     inventory stamped with that account. It then re-adopts each phone-origin entry it has no row
     for, as delivered.
   - Signing out of the phone and back in therefore removes nothing from the Watch.
   - A refresh failure is not logout (SECURITY rule 8a). It deletes no rows and changes nothing here.
6. **The phone learns why it rejected a status report, and nothing more.**
   - Acceptance returns one of three outcomes: accepted, signed out (no stamp), or other account
     (stamp mismatch).
   - The two rejections give readiness that fact only. Nothing else in the report is used.
   - A new capability, `absSend`, gates Audiobookshelf sends. A Watch without it shows "Update
     Whirr on your Watch" on Audiobookshelf rows, while RSS rows keep working.
7. **Phone storage.**
   - A new table, `absWatchCopy` (migration v106), keyed by account, item and episode.
     - It references `account` with cascade, and has no foreign key to `item`.
     - It uses `rssWatchCopy`'s state vocabulary and constraints.
     - It is not synced or backed up.
   - The device-owned `rssWatchCopySet` row gains `absGeneration` and `absAcknowledgedGeneration`.
     Nothing is renamed.
   - Watch-origin downloads have no table row. The last inventory's Audiobookshelf half is kept in
     its own `UserDefaults` record, which is cleared on account change.
8. **One phone front over two models.**
   - `ABSWatchCopiesModel` sits beside the unchanged RSS `WatchEpisodeCopiesModel`. It owns:
     - an account-bound, epoch-checked publisher;
     - its own inventory sequence;
     - the send gate.
   - A `WatchCopies` front replaces the concrete type of the `\.watchEpisodeCopies` environment
     value.
     - Per-item calls route by the item's source.
     - The list, readiness, budget and lifecycle are merged across both models.
   - At the view boundary, an AppModel `WatchCopyState` replaces the Persistence enum. It keeps the
     seven RSS states, plus who removed a copy and the decline or failure reason.
   - **Layers.** The models and the front live in `App/Whirr/Watch`. The store lives in
     Persistence and uses no `WatchProtocol` type.
9. **The wire stays at version 1, with optional fields only.**
   - The inventory gains three optional stored properties: `absEntries`,
     `absAcknowledgedGeneration` and `absAccountStamp`.
   - RSS and Audiobookshelf entries share one 100-row cap, in the offer and in the inventory.
   - The Audiobookshelf offer has its own 64 KiB cap. Its `fitting` trims the tail, as the RSS
     offer's does.
10. **One rule decides a group's state, and failures before enqueue are recorded.**
    - `WatchDownloadGroup.make` moves from the Watch app into `WatchPlayback`.
      - It gains an `enqueuing` state, because today a part-queued book reads as failed.
      - It gains a `declined` state for storage.
    - A failure before any manifest exists is recorded per selection and revision, with new
      tolerant reasons: `item_missing`, `no_audio` and `plan_invalid`.
    - The Watch retries it only on a new revision, or, for a network failure, when the network
      returns.

## Consequences

- **New cross-layer types**, each with Core tests where the type is pure:
  - `WatchProtocol`: `WatchABSSendOffer`, `WatchABSInventoryEntry`, the three inventory fields and
    `WatchStatusCapability.absSend`.
  - `WatchPlayback`: the group-state rule, offer application and the failure record.
  - `Persistence`: `absWatchCopy` and the set-row columns.
  - `AppModel`: `WatchCopyState` and a book counterpart of `PodcastEpisodeWatchCopy`.
  - App: `ABSWatchCopiesModel`, the `WatchCopies` front and the status-report outcomes.
  - The Watch app has no test target, so its wiring is verified on devices.
- **The environment value changes type.** Views that read only the per-item calls change only the
  type name.
- **Two fixes to the existing wrist path come with it.**
  - The podcast planner validates only the requested episode. Today one bad episode in a show blocks
    every other.
  - A duplicate enqueue means "already held". The false "Check Watch storage" goes with it.
- **Finished-item removal is judged on the phone.** It covers phone-origin Audiobookshelf items
  only. It waits for the Watch's finish to sync, so it lags; accepted. The setting keeps its
  stored key.
- **No new dependency, target, entitlement or capability.**
- **Documents to amend in the same change:**
  - SECURITY: Audiobookshelf sends add no credential path, and the offer carries only the account
    stamp's hashes.
  - `site/privacy.html`: books and episodes on the Watch can be started from the phone.
  - ARCHITECTURE: a decision-log row.
  - The ADR index: this row's status on acceptance.
- **Delivery is two branches.** The Watch and wire branch ships safely alone, because a current
  phone ignores the new keys and capability. The phone branch follows it.

## Alternatives

- **A one-shot "download this" command** (WSA-OD1). Rejected: it has no acknowledgement or failure
  path, so the phone would have nothing true to show.
- **Audiobookshelf rows inside the RSS offer.** Rejected: an RSS entry decodes strictly and
  requires an enclosure, so an older Watch would drop the whole mixed offer.
- **One table with a source column.** Rejected: `rssWatchCopy` cascades from `rssEpisode`, and
  Audiobookshelf rows have no such parent.
- **A device-owned Audiobookshelf desired set**, which would survive logout as RSS's does. Rejected:
  it would keep account-linked item identities after logout, against SECURITY rule 8. Decision 5
  keeps the Watch's copies without it.
- **Adopting Watch-origin downloads into the phone's set** (WSA-OD2). Rejected: a stale offer could
  then delete something just downloaded on the wrist.
- **The phone plans the files** (WSA-OD8). Rejected: it duplicates `WatchDownloadPlanner` on the
  phone and needs a token-free request shape. If a background launch is too short for `detail()`,
  the persisted offer starts the download the next time Whirr runs on the Watch.
- **A third background session for phone-sent downloads.** Rejected: session identifiers must be
  unique, and the existing per-account session already does the work.
- **A separate unstamped "Watch account state" message** (WSA-OD10). Rejected: a new key for one
  bit, when the status report already arrives.

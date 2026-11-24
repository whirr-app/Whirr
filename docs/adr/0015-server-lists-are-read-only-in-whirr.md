# ADR 0015: Audiobookshelf collections and playlists are read-only in Whirr

- Status: Accepted (2026-11-08, Rhys)
- Date: 2026-11-08
- Supersedes: `collections-playlists-editing-plan.md`
  and the add-to-playlist entry of
  `list-actions-simplification-plan.md` (LA-OD2)

## Decision

Whirr shows the server's collections and playlists but never changes them. On those screens a
listener can browse, play, add to Up Next, pin a list for download, and multi-select entries for
the actions that act on the listener's own things: Download, Mark as Finished, Reset Progress,
Add to Up Next, Save for Later and Remove Downloads.

Whirr offers no create, add, remove, reorder or delete for a server list. A footer under the
Library's Collections mode and under each list says that they are edited in Audiobookshelf on
the web. The editing code is deleted rather than hidden; the tag `pre-readonly-lists` marks the
last commit that had it.

## Why

- **One place to keep things.** Saved for Later, Up Next and the server lists all answered "keep
  this", so a long press offered four destinations with nothing to tell them apart. Saved for
  Later is Whirr's own list and stays the one "keep this" action.
- **Playlists fit that job badly.** A playlist belongs to one library, cannot hold a native RSS
  episode, and is deleted by the server when its last item goes.
- **Collections were mostly read-only already.** Editing one needs the server's `update`
  permission, which most of the family's accounts lack.
- **Less code.** The editing added about 5,000 lines across `ABSApi`, `Persistence`,
  `SyncEngine`, `AppModel` and the App, with a permission read, online-only write handling and
  an empty-playlist confirmation, for a feature only days old.

## Consequences

- Finished items accumulate in a playlist and cannot be cleared on the phone. If that becomes a
  nuisance, a single "Remove finished" action is the narrow fix, not a return of full editing.
- More than one Whirr-owned list (several named lists beside Saved for Later) is the intended
  route to "more lists", and needs its own plan.
- Restoring editing means reverting this decision first, then recovering the code from
  `pre-readonly-lists`.

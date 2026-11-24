# ADR 0002: Device-side podcast auto-download

- Status: Accepted
- Date: 2026-07-28
- Amended: 2026-08-13; ADR 0004 narrows the blanket RSS-origin prohibition

## Decision

Keeping the newest episodes of chosen shows downloaded on this device is a policy layer over the
existing, already-composed download pipeline. It introduces **no new server route**: no feed
read, no `checknew`, no `download-episodes`, no queue mutation, and no RSS-origin contact for the
ABS/server-podcast machinery governed here (native subscription traffic is governed by ADR 0004).
It downloads only files the server has already stored, through the same per-file endpoint
API-CONVENTIONS rule 24 already uses for a manual tap
(`GET /api/items/{id}/file/{fileid}/download` via the background `URLSession`). Rule 26 is
restated unchanged: the client reads the server's podcast library and does not manage feeds;
`media.autoDownloadEpisodes` and the server's other auto-download fields stay read-only and
admin-owned, surfaced diagnostically and nothing more. (**Amended 2026-11-11:**
[ADR 0017](0017-edit-server-podcast-automation-settings.md) lets an eligible administrator change
those fields from Whirr. They remain a separate object from this feature.) This feature and that server setting are
different objects — one is the RSS-to-server pipeline an admin controls from the ABS web UI, the
other is a per-device retention policy over episodes the server already holds.

ADR 0001's system-scheduled allowance — episode metadata may be refreshed by a bounded, resumable
`BGAppRefreshTask` — extends to *enqueuing* background downloads inside that same task, never
awaiting them: a background pass evaluates candidates and hands them to the background
`URLSession`, then returns immediately. Transfers finish out-of-process on the OS's own schedule,
identically to a manual download's transfer. No fixed timer, persistent polling loop, or socket is
introduced; the pass runs only from the same change-driven triggers already in place (a
recent-episodes shelf commit, a selected-show refresh commit, and — for the reap only — playback
completion), foreground and background alike.

Selection and retention are local and account-scoped. A candidate is a server-held, unfinished,
non-soft-deleted episode with no existing download or automatic decision, published after the
show's effective enablement floor. A completed automatic-origin row is reaped only when it falls
outside an enabled show's keep-latest-N window, or when delete-after-played is on and the episode
is finished; manual, active, queued, and in-flight rows are protected, and a manual delete is
never silently re-downloaded. The account defaults are automatic downloads off, keep-latest 3,
delete-after-played off, and cellular off; a show override may inherit or explicitly change each.

Automatic downloads are gated more strictly than a manual tap:

| Gate | Automatic | Manual |
| --- | --- | --- |
| Low Power Mode | blocks the pass | exempt |
| Cellular | requires its own `allowCellularAutoDownload` opt-in, decided at planning time | rule 25's existing `allowCellular` opt-in |
| Constrained path / low disk / auth | required | required |

A blocked automatic pass decides and enqueues nothing; it simply retries on the next trigger. The
cellular gate is deliberately a *separate* switch from rule 25's manual opt-in, decided once at
planning time rather than left to accumulate `waitingForWiFi` rows: consenting to spend cellular
data on a download you tapped is not consent to spend it on downloads you didn't ask for. A queue
of unrequested Wi-Fi-hold rows is a chore the user never signed up for.

## Consequences

Rule 26 remains exactly as written; this ADR adds no exception to it and touches no route it
forecloses. Because gating and the cellular decision happen entirely at planning time inside the
existing coordinator, no new background scheduling primitive, timer, or polling loop is required —
the feature rides the triggers and the `BGAppRefreshTask` registration ADR 0001 already
established. Retention (reaping automatic-origin downloads) and selection (choosing candidates)
are separate, idempotent database queries; neither contacts the server, so nothing here creates a
second place the app talks to Audiobookshelf about podcasts.

If the server later grows a genuine user-scoped feed-management facility, this ADR does not
foreclose it — rule 26 already says as much — but such a change would be a new decision, not an
extension of this one.

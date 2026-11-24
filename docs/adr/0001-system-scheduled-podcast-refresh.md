# ADR 0001: System-scheduled podcast metadata refresh

- Status: Accepted
- Date: 2026-07-27
- Amended: 2026-08-07 to describe the implemented recent-episodes path
- Amended: 2026-08-13; ADR 0004 narrows the blanket RSS-origin prohibition

## Decision

Podcast episode metadata may refresh in a system-budgeted iOS `BGAppRefreshTask`. Foreground and
explicit refresh remain the correctness paths because the system may delay or skip background work.
Fixed timers, persistent polling, sockets as a correctness dependency, and RSS-origin traffic for
the ABS/server-podcast machinery governed here remain prohibited; native subscription traffic is
governed by ADR 0004. Audiobookshelf's mutating/admin feed routes remain prohibited.

The background task:

1. exits during Low Power Mode or on a constrained/cellular path;
2. reads the known podcast-library IDs locally;
3. requests `GET /api/libraries/{id}/recent-episodes` once per podcast library, sequentially;
4. asks `RecentEpisodeRefreshCoordinator` to commit the combined successful shelf;
5. after the coordinator returns without a persistence error, runs one local auto-download
   selection and reap pass; and
6. enqueues eligible transfers into the existing background `URLSession` without awaiting them.

The system owns the task's wall-clock budget and cancels the wrapping task. Shelf work observes that
cancellation, and the wrapper checks once before starting post-pass work; detached launch
reconciliation plus auto-download/reaper flights do not yet prove cooperative cancellation
throughout or a global library/reap bound (B9). No independent timer is started. Each submitted
refresh request uses an `earliestBeginDate` four hours out; that is a resource hint, never a promised
cadence.

Opening a show uses `PodcastRefreshCoordinator` to fetch its complete episode list. That path owns
generation/deletion inference. The recent-episodes shelf is partial and therefore never infers
deletion.

## Consequences

- One request per podcast library replaces the retired one-request-per-show catalogue crawl.
- A per-library fetch failure does not discard successful shelves from other libraries. A thrown
  persistence failure prevents auto-download work. Today an all-failed fetch (or a successful empty
  shelf) can return normally without a commit and still trigger the local selection/reap pass; B9
  tracks the mismatch with the stricter commit-gated intent.
- Cold background composition creates only the account/API/persistence/network/podcast/download
  services needed for the pass. It does not start playback, artwork warming, library traversal, or
  outbox drain. It **does** run download launch reconciliation, which can reattach/requeue known
  transfers and cancel orphan tasks before the podcast pass.
- ADR 0002's device auto-download remains a policy over files already held by the server; this ADR
  does not authorize feed administration or RSS traffic for the ABS/server-podcast machinery it
  governs. Native subscription traffic is governed by ADR 0004.

## Superseded approach

The first implementation refreshed changed shows through a resumable catalogue crawl bounded by
show count and elapsed time. Live verification established that Audiobookshelf 2.35.1 exposes the
recent-episodes route, which answers the Home/auto-download freshness question directly. The crawl
was removed; git history retains its task history.

## Task IDs

Source comments and older documents cite `PBR.*` task IDs from the podcast background-refresh
plan, which was removed from the working tree once this ADR became the standing contract. The IDs
are recorded here so those citations still resolve; the plan itself is recoverable from git
history.

| ID | Work |
|---|---|
| PBR.0 | Live verification spike against a real server |
| PBR.1 | This ADR and the accompanying policy amendment |
| PBR.2 | Server change signal on the item row (migration v7) |
| PBR.3 | Durable refresh state and candidate selection (migration v8) |
| PBR.4 | Injected progress snapshot and a pre-fetched-detail entry point |
| PBR.5 | Catalogue coordinator: routing, batching, gate, budgets |
| PBR.6 | Foreground and explicit trigger integration |
| PBR.7 | Apple background scheduler |
| PBR.8 | End-to-end regression and supervised device acceptance |

PBR.3 through PBR.5 describe the resumable catalogue crawl and no longer correspond to code; see
"Superseded approach" above.

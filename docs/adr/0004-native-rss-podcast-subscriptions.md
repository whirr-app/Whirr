# ADR 0004: Native RSS podcast subscriptions

- Status: Accepted
- Date: 2026-08-13
- Amended: 2026-09-01 (bounded NP12 server-copy carve-out; direct RSS boundaries unchanged)
- Amended: 2026-09-29 (class 1 names the user-opened pre-follow preview fetch; see
  the private directory podcast detail plan)
- Amended: 2026-09-29 (class 4 lets the directory detail hero ask the directory image host for
  a larger size of the image a search result returned)
- Amended: 2026-11-21 (class 5, Watch-origin enclosure fetch; see
  [ADR 0020](0020-watch-fetches-rss-episodes-and-reports-status.md))

## Decision

Whirr adds device-owned podcast subscriptions fetched directly from RSS origins, alongside — not
replacing — the Audiobookshelf podcast library. This supersedes the "never contacts RSS origins"
sentence written into ADR 0001, ADR 0002, ARCHITECTURE §4, API-CONVENTIONS rule 26, and
PRODUCT-REQUIREMENTS requirement 7, for exactly five classes of non-ABS traffic:

1. **Feed fetch** — GET of a subscribed feed's document over http(s), with conditional GET
   (`If-None-Match`/`If-Modified-Since`) so an unchanged feed costs a 304. Class 1 also covers a
   **preview fetch**: one GET of a feed the user has explicitly chosen to inspect before following
   it, either a pasted address or a directory result the user opened. Add-by-URL and the
   directory follow always made this GET before committing. The 2026-09-29 amendment names it and
   lets it stand without a follow. A preview persists nothing: no subscription or episode row, no
   persisted validator, no feed-declared artwork fetch, and no enclosure request. It carries no feed
   credential unless the user supplied one for that preview.
2. **Enclosure transfer** — streaming or downloading a subscribed episode's audio from the URL the
   feed declares, including the cross-origin CDN redirects real feeds use.
3. **Directory search origin** — show discovery through the iTunes Search API (keyless,
   accountless). Add-by-URL and OPML import work without it.
4. **Artwork fetch** — show artwork explicitly declared by a followed feed, plus iTunes thumbnail
   URLs returned on directory-search results. A returned `…/600x600bb.<ext>` image on the
   directory's own `mzstatic.com` host may also be requested as `…/1200x1200bb.<ext>`, which is the
   same image at the size a full-width detail hero draws; nothing else about the URL may change,
   and a failure falls back to the returned URL. HTML/page scraping, description images, arbitrary
   episode links, and unrelated third-party artwork are not artwork inputs.
5. **Watch-origin enclosure fetch** — the Apple Watch app downloads one subscribed episode's audio
   from the enclosure URL in an offer the iPhone sent after the listener chose that episode, under
   the bounds and post-completion redirect rule of
   [ADR 0020](0020-watch-fetches-rss-episodes-and-reports-status.md). No credential, feed fetch,
   artwork or directory traffic originates on the Watch.

The accepted [ADR 0006](0006-save-native-podcast-episodes-to-audiobookshelf.md) decision adds a
separate, bounded server-side copy path for one stored native-RSS episode. This is not a direct
RSS-origin traffic class: Audiobookshelf fetches the enclosure after Whirr's explicit
request. AppModel passes only an opaque feed/episode identity and destination choice; a
Persistence-backed command reader validates the current subscription, absolute HTTP(S) enclosure,
credential/private-feed exclusion, and account capability (`admin`/`root` + active + `update` for
Save or `delete` for Remove); then the account-fenced `SyncEngine` coordinator is the only path
allowed to construct the bounded `ABSApi` mutation. Raw enclosure URLs and credentials never enter
AppModel state or logs. The path is limited to the three routes and save/remove conditions in ADR
0006; it does not authorize feed administration or broad server podcast administration. (The
separate automation-settings write is [ADR 0017](0017-edit-server-podcast-automation-settings.md).)

No other direct RSS-origin or third-party traffic is authorized. The scope is bounded by mechanism,
not intention:

- Feed, enclosure, and directory traffic run through the bounded `PodcastFeeds` policies. RSS
  artwork uses a separate source-specific pool capped at two concurrent requests, plus a separate
  cache and identity namespace. It consumes no ABS artwork slot, credentials, reachability, or
  outage state. No RSS pool is composed with `ReachabilityObservingHTTPClient`: a dead feed or
  artwork host must not assert an ABS outage, and ABS reachability must not gate RSS traffic.
- Redirects follow a dedicated `FeedRedirectPolicy`: bounded hops, cross-origin permitted,
  https→http downgrade rejected, `Authorization` stripped on cross-origin hops. ABS traffic keeps
  `ABSRedirectPolicy` byte-for-byte.
- Parsing uses Foundation `XMLParser` only — no third-party feed parser enters the dependency
  graph — with element-count and string-length caps and hostile-input fixtures.
- Enclosure sizes are untrusted (declared lengths lie in both directions): every RSS transfer is
  capped at 1 GiB regardless of its declared length, unknown-size transfers additionally reserve
  500 MB of free disk, overrun is cancelled in flight, and completion validates actual bytes
  against the cap and the final HTTP response's own length — never against the declared length,
  which is a free-space estimate and not a checksum.
- Feed URLs must be absolute http(s) without embedded credentials. Private feeds (NP11)
  authenticate through a sibling credential type held in the Keychain, never through
  ABS-credential types or headers.
- RSS artwork identity is source + feed identity + normalized artwork URL. Feed identity is the
  followed feed's stable identity or the directory provider's stable result identity before
  follow. A URL change creates a new identity. A stable URL is refreshed when its HTTP `ETag` or
  `Last-Modified` validator changes; when the server supplies neither validator, the existing entry
  is periodically revalidated instead of minting a new cache identity on each feed refresh.
- Feed credentials may accompany artwork only when the artwork URL's origin exactly matches the
  feed origin. Artwork redirects are bounded; cross-origin redirects are permitted only after
  stripping `Authorization`, and https→http downgrade is rejected. Directory thumbnails never
  receive feed credentials. Every admitted artwork response remains subject to the existing cover
  byte and image-MIME limits before caching or decoding.

**Ownership and identity.** Subscriptions, episode rows, episode state, per-feed settings, and
downloaded RSS audio are device-owned: parallel tables with no account foreign key and a
non-account `RSS/` file root, surviving logout and account removal (the `accountRemovalJournal`
precedent). RSS state never touches `mediaProgress`, `PlaybackSessionStore`, or the upload outbox
— there is no second writer by construction, and nothing about a native subscription is ever
synced to, or inferred from, the ABS server. Routers dispatch on a typed source identity; the
serialized namespace `rss:` is reserved and enforced at sync ingest. The universal listening queue
remains account-owned: queue rows, RSS entries included, clear on logout.

**Orchestration boundary.** `SyncEngine` remains the sole post-login ABS orchestrator. Native RSS
feed, enclosure, directory, and artwork network orchestration never enters it; the one existing
touch is provider-neutral playback lifecycle forwarding through the playback router
(backgrounding/foreground/quiescence fan-out), where the RSS side only flushes local state. The
accepted NP12 exception is different: its bounded coordinator may read a stored native episode
and ask `ABSApi` for one eligible server-side save/remove operation. It does not move RSS fetches
into `SyncEngine`, expose an enclosure to AppModel, or create a direct AppModel-to-ABS path.

**Gating.** An ABS account is still required; Whirr is not a standalone no-login podcast app.
Settings gains a "Native podcast subscriptions" toggle, on by default and inert until the first
subscription. Off means the app behaves exactly as before this ADR: no RSS UI, no RSS network, the
background refresh leg disarmed, and active RSS playback stopped — data retained dormant.

## What remains prohibited

- Audiobookshelf admin feed/queue routes, feed administration, and broad server-side episode
  download management remain prohibited. The sole exception is ADR 0006's three routes for one
  explicit, eligible admin/root save/remove mutation; it does not authorize feed checks, queue
  control/clear, scans, retention or auto-download changes, show edit/delete, pre-existing episode
  removal, arbitrary URL/path input, ordinary-user writes, private feeds, or any other server
  podcast administration.
- The server's `media.autoDownloadEpisodes` and related fields stay admin-owned. **Amended
  2026-11-11:** [ADR 0017](0017-edit-server-podcast-automation-settings.md) lets an eligible
  administrator change those four fields from Whirr through one route; everything else in this
  list stands.
- Fixed timers, persistent polling, and sockets as a correctness dependency (ADR 0001's frame).
  RSS refresh rides the same system-budgeted background machinery; whether it reuses the existing
  task identifier or registers a second one is deliberately undecided until NP9, and either answer
  stays inside ADR 0001's budget discipline.
- RSS traffic through ABS client pools, ABS traffic through the feed pool, and any composition
  that lets one origin's failure or reachability speak for the other.
- NP12 does not add a timer, persistent poller, socket, or pool/reachability composition; its
  account-owned attempt transitions are durable before each next network step and its uncertain
  responses reconcile before an explicit retry.
- HTML/page scraping, description-image discovery, arbitrary episode artwork links, unrelated
  third-party artwork, or credential forwarding beyond the feed's exact origin.
- Enclosure requests from the Watch that no iPhone offer named, and any Watch-originated request
  for a private (credentialed) feed (ADR 0020).
- Contacting RSS origins while the native-subscriptions toggle is off, or for shows that are ABS
  library content rather than native subscriptions.
- Fetching a feed the user has not opened, such as prefetching directory results' feeds to enrich
  a search list, and streaming, downloading or fetching artwork for a feed that is only being
  previewed.

## Consequences

- ADRs 0001 and 0002 remain in force for the ABS podcast section. Their RSS-prohibition sentences
  are narrowed by reference to this ADR, not deleted; ARCHITECTURE §1 (dependency table +
  `PodcastFeeds`) and §4, API-CONVENTIONS rule 26 plus a new feed-pool rule, SECURITY.md (threat
  model, per-feed credentials, the transfer cap), and PRODUCT-REQUIREMENTS are amended in the same
  accepted-policy change. NP12 implementation remains on its own branch and must follow the
  plan's G4 review and later lifecycle/device gates; no direct RSS network path is changed here.
- `PodcastFeeds` enters the `LayeringTests` dependency table; the release audits (package pins,
  licences, background identifiers) continue to gate mechanically.
- Because the lifecycle is device-owned, native subscriptions are invisible to iCloud
  settings mirroring and to any future multi-account work; a future standalone (no-ABS-account)
  mode remains possible but is a separate decision — no task may newly bake in an auth assumption
  beyond what exists today.
- The Podcasts tab becomes RSS-primary. The later accepted One Your Shows amendment presents native
  and ABS shows in one mixed root grid, marks each tile with its source, and keeps each source
  reachable through the `Followed` / `On your server` picker. Each source still orders itself, and
  the ABS `podcastShowOrder` machinery is untouched. That per-tile mark was first a caption line
  reading **On your server** under the publisher; it is now a symbol in the artwork's trailing
  corner — a server for an ABS show, an RSS glyph for a followed feed — because the caption grew
  every tile in the grid by a line and left dead space on the tiles with nothing to say there. The
  wording survives as each mark's spoken accessibility value and as the picker's server title.

# Architecture

This is the current structural contract. Changes to target ownership, dependency direction, or the
network/data invariants require an entry in the decision log or a focused ADR.

## 1. Package shape and dependency direction

The Xcode app is the composition and platform shell. Most behavior lives in one local Swift
package and is testable on macOS.

```text
iPhone App
├── AppModel ──┬── SyncEngine ──┬── ABSApi
│              │                ├── Persistence ── GRDB
│              │                └── CoreSupport
│              ├── PlayerCore
│              ├── ReaderCore ───── CoreSupport
│              ├── Persistence
│              ├── PodcastFeeds ──┬── ABSApi
│              │                  └── CoreSupport
│              ├── AdSkip (pure, D43; ad skip, transcripts, Look Back)
│              └── CoreSupport
├── DesignSystem
├── AdSkip (the App's speech, silence and scorer adapters implement its protocols)
├── App/Whirr/Watch adapters ── WatchProtocol
├── App/Whirr/Widgets adapters ── WidgetProtocol
└── iOS-only adapters (AVFoundation, background URLSession, Readium, lifecycle)

Watch App ─┬─ WatchPlayback ──┬── ABSApi
           │                  ├── PlayerCore
           │                  └── WatchProtocol
           └─ PodcastFeeds (enclosure URL and size rules only, ADR 0020)
App/WatchShared ── compiled into both App targets
Widget Extension ── WidgetProtocol (nothing else from the package)

```

Exact SwiftPM target dependencies are mirrored in `Packages/Core/Package.swift` and checked by
`LayeringTests`. SDK imports are listed separately so this table does not confuse framework imports
with package edges:

| Target | Declared package-target dependencies | Notable SDK modules |
|---|---|---|
| `WatchProtocol` | — | Foundation, guarded CryptoKit; source-qualified companion wire values and pure safety policy (ADR 0003) |
| `WatchPlayback` | `ABSApi`, `PlayerCore`, `WatchProtocol` | Foundation/CryptoKit; Watch-owned account, catalogue, session and offline services, no GRDB |
| `WidgetProtocol` | — | Foundation, guarded ActivityKit (iOS only); App Group snapshot values, bounded codec, storage layout, the sleep-timer activity's attributes, and the pure presentation rules the extension draws with (shelf, controls, stats) (ADR 0014) |
| `CoreSupport` | — | Foundation; `os` only for `CoreLogging`, which vends every Core `Logger` |
| `ABSApi` | — | Foundation, CryptoKit (hashing only); Security only in the guarded Keychain adapter |
| `PodcastFeeds` | CoreSupport, ABSApi | Foundation, CryptoKit |
| `Persistence` | GRDB | Foundation, Synchronization, CryptoKit, os |
| `SyncEngine` | CoreSupport, ABSApi, Persistence | Foundation, CryptoKit (opaque podcast identity hashing), Compression (bounded decoding of the podcast backup's learned-ads blob); also imports GRDB, undeclared, reached through Persistence by the podcast cloud-sync reconcilers (see note below) |
| `PlayerCore` | — | Foundation, Observation |
| `ReaderCore` | CoreSupport | Foundation |
| `AppModel` | CoreSupport, Persistence, SyncEngine, PlayerCore, ReaderCore, PodcastFeeds, AdSkip | Foundation, Observation, CryptoKit, Synchronization |
| `DesignSystem` | — | SwiftUI plus platform UI/graphics modules; consumed by App only |
| `AdSkip` | — | Foundation; the pure podcast ad-skip pipeline (D43); its package consumers are AppModel's `AdSkipCoordinator`, `EpisodeTranscriptCoordinator` and `LookBackCoordinator`, which share one recogniser through `TranscriberGate`, and the App implements its adapter protocols |
| `TestSupport` | ABSApi, Persistence, SyncEngine, PlayerCore, ReaderCore, AppModel, GRDB (test-only) | Foundation |

`PodcastFeeds` owns the bounded RSS/Atom feed transport, parsing, episode identity, and OPML
boundary approved by ADR 0004. AppModel consumes it for feed preview and refresh orchestration.
The App target imports it only in composition and transport adapters (`AppEnvironment*`,
`RSSArtworkCacheClearing`, the background-download adapter's `FeedRedirectPolicy`); no view imports
it, and screens receive plain display values from AppModel.

**Open owner question (found 2026-11-03).** Ten SyncEngine files (the `PodcastCloud*` reconcilers
and appliers) `import GRDB`, which SyncEngine does not declare; it compiles because Persistence
brings GRDB into the build graph, and `LayeringTests` checks only package-target edges. Either the
edge is blessed here and declared in `Package.swift`, or those files move their GRDB use behind
Persistence. Until Rhys decides, the table records the import as found.

The boundaries are deliberate:

- Wire DTOs belong to `ABSApi`; database records belong to `Persistence`; mapping happens in
  `SyncEngine`.
- Screens bind to `AppModel` and persisted projections. Business and sync decisions do not live in
  SwiftUI views. App-only presentation policy may have focused tests in `WhirrTests`.
- AVFoundation, background `URLSession`, Readium, and non-UI UIKit lifecycle work stay behind
  protocols/adapters in the app target. DesignSystem may use platform UI/graphics modules; ABSApi
  has the guarded Keychain/Security exception.
- Production targets never import `TestSupport`.

The approved [ADR 0009](adr/0009-standalone-podcasts-and-private-cloud-state.md) assigns portable
podcast cloud mutation values, identities and pure conflicts to `SyncEngine`. The CloudKit runtime
(`PodcastCloudSyncComposition`, `PodcastCloudKitSyncEngineAdapter`) is an App SDK leaf, composed
only after device-local consent. That runtime is the app's only `CKSyncEngine`.
`Persistence` does not import SyncEngine. The app still requires an Audiobookshelf account: the
ADR's standalone runtime was dropped by its 2026-09-25 scope amendment.

### Watch composition and boundaries

The Watch owns independent credentials, playback sessions, downloads and offline progress through
`WatchPlayback`; its declared dependencies are `ABSApi`, `PlayerCore` and `WatchProtocol`
(`Packages/Core/Package.swift:37`). The Xcode Watch target also links those products directly
(`App/Whirr.xcodeproj/project.pbxproj:219`). Since ADR 0020 it also links `PodcastFeeds`, for the
enclosure URL validation and size rules of the Watch-origin enclosure fetch; it makes no feed,
artwork or directory requests. On iPhone, `App/Whirr/Watch` adapters consume AppModel
companion projections/actions and map them to WatchProtocol values; AppModel has no WatchProtocol
package edge (`App/Whirr/Watch/WatchCatalogueWireMapper.swift:2`, `Packages/Core/Package.swift:52`).
`App/WatchShared` contains the journal and ownership sender, compiled into both targets through
synchronized-group membership (`App/Whirr.xcodeproj/project.pbxproj:215` and `:244`). It is shared
App source, not another package. [ADR 0003](adr/0003-watch-shared-protocol-module.md) governs the
protocol leaf.

Since [ADR 0021](adr/0021-iphone-sends-audiobookshelf-items-to-the-watch.md) the iPhone also sends
Audiobookshelf books and episodes. Their desired set is the account-owned `absWatchCopy` table in
`Persistence`, which uses no WatchProtocol type; `App/Whirr/Watch` maps it to and from the wire
(`ABSWatchSendPublisher.swift`, `ABSWatchInventoryInbox.swift`), and AppModel's `WatchCopyState` is
the one copy state both desired sets map into for the screens. No package edge changed.

`WatchWireCodec` validates before encoding and after decoding, bounds both directions by each
value's `maxWireBytes`, and emits sorted-key JSON. Dates use `.deferredToDate` (Double seconds since
Foundation's reference date), preserving exact setup-expiry comparisons. Commands, replies,
snapshots, browse, setup and ownership values implement `WatchWireValue`; the families retain their
own shapes rather than a generic wire envelope. Persisted WatchPlayback envelopes separately use
milliseconds since 1970 (`Packages/Core/Sources/WatchProtocol/WatchProtocol.swift:672`,
`Packages/Core/Sources/WatchPlayback/WatchAccountFencedJSONStore.swift:67`).

`WatchPhoneRequestRunner` supplies bounded decode/reply helpers and a generic decode → account
stamp → action → bounded keyed reply path. Browse, ownership queries and advertisements use the
full runner; handoff uses its decode/reply helpers while retaining admission and drain ordering.
The command endpoint still invokes `WatchWireCodec` directly and owns deduplication, deadlines and
binding fences. Advertisement acknowledgement deliberately echoes admitted bytes. These are
endpoint policies, not a uniform transport wrapper
(`App/Whirr/Watch/WatchPhoneRequestRunner.swift:6`,
`App/Whirr/Watch/WatchPhoneBrowseEndpoint.swift:30`, `App/Whirr/Watch/WatchPhoneBridge.swift:205`,
`App/Whirr/Watch/WatchPhoneHandoffEndpoint.swift:144`,
`App/Whirr/Watch/WatchPhoneCommandEndpoint.swift:65`).

`WatchLibraryModel` is the MainActor observable façade over session, catalogue, playback, offline
sync and download controllers. It keeps the view API and publishes only changed projections; its
injected catalogue loader supports deterministic paging. Controllers share an immutable
`WatchSessionContext` with account identity, epoch and services. `WatchSessionLifecycle` cancels
initialization, restore, install, timer and reconciliation tasks; epoch checks still fence replies
already delivered during teardown (`App/WhirrWatch Watch App/WatchLibraryModel.swift:9`,
`App/WhirrWatch Watch App/WatchSessionContext.swift:7`).

`WatchDownloadURLSessionAdapter` owns background-session configuration, delegate callbacks, task
recovery and synchronous preservation of temporary files before delegate return. Callback tokens
carry download, task and generation identity; pending callbacks delay background completion.
`WatchDownloadManager` receives those events on MainActor, rejects stale work, applies request and
renewal policy, and publishes the durable `WatchDownloadStore` manifests. Its initializer injects
request providers and Wi-Fi availability but constructs the concrete transport internally
(`App/WhirrWatch Watch App/WatchDownloadURLSessionAdapter.swift:6`,
`App/WhirrWatch Watch App/WatchDownloadURLSessionAdapter.swift:231`,
`App/WhirrWatch Watch App/WatchDownloadManager.swift:47`,
`App/WhirrWatch Watch App/WatchDownloadManager.swift:63`).

`WatchRSSDownloadDriver` owns the Watch's second background session, the RSS one from ADR 0020. The
received-episode store is its only source of truth, so an offer, a launch, a wake and a finished
task all reconcile the system's tasks against the store's pending downloads, two at a time. It
carries no credential or header, judges the redirect chain from task metrics and the response after
completion, and commits through the same store and 2 GB budget the Audiobookshelf downloads use
(`App/WhirrWatch Watch App/WatchRSSDownloadDriver.swift`,
`App/WhirrWatch Watch App/WatchRSSDownloadDriver+Completion.swift`).

`WatchApplicationContextPublisher` is the single writer of the Watch's outgoing application
context. `updateApplicationContext` replaces the whole dictionary, so it composes the playing
report and the status report together, and it withholds an unchanged status until the throttle's
interval has passed (`App/WhirrWatch Watch App/WatchApplicationContextPublisher.swift`,
`Packages/Core/Sources/WatchPlayback/WatchApplicationContextComposer.swift`).

## 2. Network ownership and offline-first data flow

`ABSApi` owns request construction and foreground HTTP transport. `SyncEngine` is the only
post-login application component that orchestrates metadata, progress, session, and other API
work. Setup/login/logout are explicit account-lifecycle operations through `ABSClient`. An
account may hold several addresses for one server (`accountEndpoint`): `AccountEndpointService`
proves and stores them, `EndpointSelector` picks the reachable one, and the App's
`EndpointSwitchCoordinator` rebuilds the runtime composition on a switch only while playback and
transfers are idle, because every base-URL-bound client is built from the active address.

The production foreground pipeline is:

```text
ABSClient endpoint
  → AuthenticatedHTTPClient (Bearer injection; one refresh flight)
  → ServerRequestGate (FIFO; at most four outstanding responses)
  → RedactingHTTPLogger (metadata only)
  → URLSessionHTTPClient
```

Each `ABSClient` is fixed to one server at construction. A client composed for one account's
lifetime (the shared runtime/background bundle and setup library discovery, built through
`ABSClient.production(server:account:…)`) is also fixed to that account's `TokenAccount`. It
refuses any other account with `APIError.cancelled` in `loadTokens` and `authenticatedTransport`,
before any token read or request, so a client retained past removal or an endpoint switch cannot
carry a later account's credentials to the old server or its proxy headers. Server status, login,
re-authentication and logout do not consult the binding. Unbound clients remain only for
pre-authentication and endpoint work (login, endpoint probes and candidates, and the removal-only
default) and for the Watch; an App source scan keeps the phone's account-lifetime sites on the
bound factory. `OutboxDrainRequester` and `SyncEngine`'s refresh return before any row write when
the current account is not their client's bound account (D48).

Eight narrowly scoped exceptions do not create alternate sync paths:

1. `CoverImageClient` performs cover GETs only, with coalescing, a file-backed cache
   (`CoverFileStore`), and a six-request cap.
2. The App background-download adapter executes ABSApi-authorized requests with a two-transfer cap;
   it does not own refresh credentials or an independent retry loop.
3. The opt-in live smoke harness may call `ABSClient` with runtime-only credentials.
4. System-scheduled podcast refresh invokes a system-budgeted, opportunistic SyncEngine operation;
   its shelf response is limited per library and its end-to-end post-pass is bounded by a
   whole-pass deadline that cancels in-flight work. It is not a timer or correctness dependency.
5. The App audio adapter may execute only stream resources returned by a playback session or
   validated local files returned by the download store. It never constructs an endpoint.
6. `PodcastFeeds` performs direct feed-origin GETs under ADR 0004 through its own four-request gate,
   coalescing, byte cap, redacting logger, backoff, validator, and redirect policies. It never
   receives ABS credentials and does not report feed-origin reachability as ABS reachability.
7. RSS artwork performs only ADR-0004-authorized show-artwork and directory-thumbnail GETs through
   a source-specific two-request pool. Its cache, identity, request slots, credential routing,
   reachability, and outage state are isolated from `CoverImageClient`'s ABS namespace.
8. The accepted NP12 native-episode server-save path is a bounded mutation exception, not a second
   RSS transport. AppModel supplies only an opaque feed/episode identity and destination choice.
   A Persistence-backed command reader validates the still-subscribed, non-credentialed episode
   and its absolute HTTP(S) enclosure; only the account-fenced `SyncEngine` coordinator may then
   construct the bounded `ABSApi` request. It may call only the ADR 0006 create-if-missing,
   single-episode enqueue, and confirmed hard-remove routes. Raw third-party enclosure URLs never
   enter AppModel state or logs. This path adds no timer, poller, socket, pool, or reachability
   composition, and does not alter the independent RSS/ABS pools. The automation-settings write
   of [ADR 0017](adr/0017-edit-server-podcast-automation-settings.md) is a second, separate
   exception: one closed four-field `PATCH /api/items/:id/media`, sent by an account-checked
   `SyncEngine` service rather than this coordinator.

The five managed request/task pools are independent: foreground API 4, ABS covers 6, downloads 2,
RSS feeds 4, and RSS artwork 2. Their deliberate aggregate slot limit is 18 while the RSS feature
is composed; it is not a global socket cap, and AVFoundation media traffic sits outside those
pools.

```text
SwiftUI ──intent──▶ AppModel ──▶ Persistence (SQLite source of truth)
                       ▲                  │ durable outbox
                       │ observations     ▼
                       └──────────── SyncEngine ──▶ ABSApi ──▶ server
```

- Screens render observed local data; network completion is not a prerequisite for first paint.
- A user mutation and its outbox operation share one transaction. Rows are removed only after the
  endpoint-specific acknowledgement and local commit.
- NP12's account-owned save attempt is not an `Outbox` operation: each attempt-state transition
  and any accompanying local mutation commit in one Persistence transaction before the next
  network step, while uncertain responses reconcile before an explicit retry instead of inheriting
  Outbox replay/dead-letter or automatic mutation-retry behavior. The generic one-transaction rule
  remains unchanged for mutations that do use the outbox.
- Foreground and explicit pull refresh are correctness paths. Socket.IO is not present.
- Pagination, conflict, deletion, account-removal, and outbox semantics come from
  [SYNC-SPEC.md](SYNC-SPEC.md).

## 3. Concurrency and lifecycle

- Core builds in Swift 6 mode from its Swift 6.2 package manifest. The App currently builds in
  Swift 5 language mode with approachable concurrency and MainActor default isolation.
  `SyncEngine` is an actor; keyed queues preserve ordering across actor reentrancy where required.
- GRDB owns database serialization. Async services use async store/DAO surfaces rather than
  blocking the cooperative pool or MainActor on synchronous database work.
- NP12 captures the active account's non-reusable identity (row identity plus stable client UUID,
  with the server/user pair) at flight start and rechecks it before every persistence and
  presentation step. The existing sync-run generation is not an account fence; logout and account
  replacement must not publish a completion into a replacement account.
- UI-facing models are `@MainActor @Observable`. Their long-lived `Task` handles are
  `@ObservationIgnored` but stay MainActor-isolated, not `nonisolated(unsafe)`: Swift 6 lets the
  nonisolated `deinit` of a global-actor class read its own `Sendable` stored properties to cancel
  them, while an Observation-tracked property is a computed accessor `deinit` cannot read.
  Platform adapters deliver events through owned async sequences. Several streams use default
  unbounded `AsyncStream`; account/environment teardown is required to cancel their owners, fence
  refresh generations, shut down the old sync/download graph, and clear process-wide intent/playback
  routes before rebuilding. The release candidate implements single-flight removal, an async
  `SyncEngine` drain and a cover-fetch drain before persistence and the cover cache are removed,
  download/cover intent fencing, refresh/client invalidation for the removed account, account-bound
  clients (D48), and cache/artwork cleanup. Each traversal runs in an engine-owned task;
  `SyncEngine.shutdown()` cancels it and returns once it has ended, and a cancelled traversal stops
  at its next page boundary or before its next ancillary hand-off. Removal awaits the shutdown
  before the purge and the credential wipe, and every composition rebuild calls it on the outgoing
  engine without waiting. Cancellation is its only bound; there is no timer. The drain does not
  reach the system-scheduled background pass, native server-save convergence or the playback
  coordinator's outbox trigger; account binding is what keeps those from serving another account
  (a private decision record).
  Historical gate output is kept in dated release evidence. B7 remains open for the current
  candidate's clean gate run and the named device transfer/relaunch/lock-screen pass.
- `NetworkConditions` is the Foundation-only boundary for Low Power and constrained/cellular state.
  App supplies the Network/ProcessInfo implementation.
- `AppLifecycle` delivers foreground/background events and bounded background-task handles. App
  supplies the ScenePhase/UIKit implementation.
- `DiagnosticsRecording` is a bounded, account-scoped, privacy-safe persistence surface. It stores
  categories and timings—not payloads, tokens, or user content—and is deleted with the account.

App-wide preferences keep `UserDefaults` as their runtime source and mirror only an explicit,
tested allowlist through iCloud key-value storage. Existing iCloud values win at launch; otherwise
the device seeds missing keys. Server/account identity, credentials, database and diagnostic state,
transient view state, and downloaded media are outside that allowlist.

## 4. Audio, downloads, and podcasts

`PlayerCore` owns the global playback timeline, state reducer, rate, chapter mapping, and sleep
timer. The App's `AVQueuePlayer` adapter is selected and hardware-confirmed (D19/D37); it translates
engine events without owning sync policy.

Voice Boost is an App-only effect inside that adapter, not a `PlayerCore` concept. While it is on,
each new `AVPlayerItem` gets an `MTAudioProcessingTap` (`PreEffects`) as its audio mix, and turning
it on attaches to every queued item. The tap's render callback runs on the real-time audio thread,
so it reads only raw pointers and atomics: no allocation, locks, logging, class references or
actor hops. Its switch is one atomic shared by every tap, set from the `player.voiceBoost.enabled`
preference by `PlaybackHardware`. Turning it off ramps to a bit-exact bypass and never removes a
mix mid-play.

- Online audio uses an ABS playback session and forces direct play. HLS is not a supported release
  path because Whirr does not implement the server's Socket.IO `stream_reset` lifecycle;
  `PlaybackSessionCoordinator` therefore closes and refuses any non-zero `playMethod` or HLS track
  before it reaches the player.
- Multi-file audio maps one global timeline to track-local offsets in pure code.
- A declared duration is a starting estimate, not a fact. For a single-file item the timeline grows
  to whatever extent the engine actually reports — either the engine's own measurement or a position
  tick that over-runs the declared end — and never shrinks. Multi-file items are excluded because an
  extent measured on one track says nothing about where the following tracks begin. The rule itself
  is `PlaybackTimeline.grown(toObservedLocalExtent:)`, so both engines share one definition of when
  an observation counts: `PlayerReducer` applies it on the phone, and `WatchAudioEngine` applies it
  directly, having no reducer to route through.
- Progress ticks carry position plus listening delta. The delta resets only after acknowledgement;
  session close is durable and reconciled after interruption or relaunch.
- A fully downloaded item uses validated local files and a complete local session even while the
  server is reachable. Local sessions upload through bounded `local-all` batches.
- Background `URLSession` owns in-process/background transfer continuation. Whirr does not persist
  manual byte-range resume state; an interrupted transfer is reconciled and restarted safely.
- ABS-side podcast catalog content and feed administration belong to Audiobookshelf. Whirr reads
  the server library and retains its universal listening queue and device-download policy. An
  eligible administrator may change one show's four automation settings (ADR 0017). Native,
  device-owned RSS subscriptions exist alongside it under ADR 0004. Direct native-RSS traffic is
  limited to feed fetch, enclosure transfer, directory search, and explicitly scoped artwork; it
  never carries ABS credentials and never enters ABS orchestration. The accepted NP12 exception is
  server-side egress initiated by a bounded, account-fenced SyncEngine coordinator from a stored
  native episode: raw enclosure URLs remain below AppModel and enter `ABSApi` only for the three
  explicit save/remove mutations in ADR 0006. It does not add timers, sockets, or pool composition.
  RSS artwork keys combine source, feed identity, and normalized artwork URL, and its two-slot
  transport/cache namespace is isolated from ABS artwork. RSS listening state never touches
  `mediaProgress`, ABS playback-session rows,
  or the upload outbox. Direct RSS playback is selected by a typed pre-start route announcement
  before `PlaybackModel` emits `.buffering`; its bookmark and progress rows are device-owned. The
  account-owned listening queue carries ABS audiobooks, ABS podcast episodes, and RSS episodes in
  one ordering, so RSS starts, retained bookmarks, and completion use the same consumption and
  advance rules. Logout clears that whole queue while device-owned RSS subscriptions and state
  survive.

## 5. EPUB reading

Readium Swift Toolkit is linked in the App target behind the app-owned renderer boundary. It opens
validated local EPUB files; `ReaderCore` owns Whirr's `ReadingPosition`, `ReaderPreferences`, table
of contents values, and debounced/durable position logic.

The pinned Readium 3.11.0 archive path is `AssetRetriever` → `DefaultArchiveOpener` →
`ZIPArchiveOpener` (Minizip first, ZIPFoundation fallback) → `ContainerAsset`. It enumerates entries
and serves their bytes on demand; it never extracts the publication into a filesystem directory.
Consequently `../` entry names and symlink metadata have no extraction root to escape in this path.
That closes traversal/symlink escape as not applicable by architecture, not by a finite hostile-book
sample. The same source audit found no global expanded-byte, entry-count, per-entry, or compression
ratio admission bound, and found finite registered script-message names but no bounded payload size,
count, or string-shape policy.

Both controls are now implemented. `ReaderCore`'s `EPUBArchiveAdmission` owns the pure expansion
policy and the App's `EPUBArchiveAdmissionCheck` measures a Readium container against it between
format detection and the parser, judging entry count, per-entry and total expanded bytes, and
compression ratio from the ZIP directory without decompressing anything. On the content seam,
`ReadingPosition.validated` bounds a publication-controlled href on arrival instead of at
persistence, and table-of-contents flattening bounds nesting depth, entry count, and title length —
the depth bound making the flatten's recursion finite, where publication nesting previously set it.
The admission limit values remain provisional until calibrated against a real library.

The serialized app-owned `ReadingPosition` is the local source of truth; the App maps Readium's
locator into that bounded value. Current cross-device sync and restore are fraction-only through
normalized `ebookProgress`: Readium supplies a partial CFI, Whirr's complete-CFI gate drops it, and
inbound stored CFI is not used for restore. Exact CFI sync remains unimplemented. Readium types,
WebKit/UIKit details, and locator text context do not cross into Core persistence.

## 6. UI architecture

Whirr uses SwiftUI screens and `TabView(.sidebarAdaptable)` with one `NavigationStack` per section.
One `NavigationModel` owns section paths and app presentations. DesignSystem owns reusable tokens
and components; feature-specific composition remains in App.

Liquid Glass is control-layer chrome, not content decoration. System presentations, lists,
toolbars, swipe actions, and accessibility behaviors are preferred where they express the product
interaction. Every custom animation or glass treatment supplies appropriate Reduce Motion,
Reduce Transparency, Dynamic Type, contrast, and VoiceOver behavior.

The reader draws no bars of its own. Its close button, menu, and progress rail are items on the
system toolbar inside the reader's `NavigationStack`, shown and hidden with `toolbarVisibility`,
so the system supplies their glass and its accessibility fallbacks. The page ignores the safe
area those bars add; Readium's fixed content insets leave the header and footer rows blank for
the toolbar and for the running header and footer drawn in the margins.

The expanded player is a UIKit-owned custom presentation with an artwork-derived canvas (D39).
SwiftUI renders the page; UIKit owns the transition, the pull-down gesture and its arbitration with
the page's scroll view, interactive progress, cancellation, and teardown. Nested player controls
and sheets keep their own gestures; a VoiceOver/keyboard dismissal path is always available.

A failure that many surfaces can raise — a refused playback start, a playback-speed write the
database did not accept — is reported by one alert attached at the app root (`RootView`) rather
than by an alert on each surface that can trigger it. A root alert can make UIKit dismiss the
expanded player; the presentation releases its host when that happens, so a later expand is not
lost.

Artwork-derived colour follows two surface rules. Ambient full-page canvases — the expanded player
and item detail — take the weighted dominant cluster's colour, with page lightness clamped into a
band where the chosen ink clears AA. App appearance owns the variant: Light always uses a pale
canvas with dark ink, Dark a deep canvas with light ink. Artwork never changes the window's
appearance. Each presentation holds its entry palette (or an appearance-matched neutral if no
palette is cached), so asynchronous extraction cannot recolour a page that has settled. User
appearance and contrast changes resolve the same retained palette. A player item change selects
again, and because that page keeps one view identity across queue advances its new selection is
provisional while it is neutral: a palette extracted for the incoming item is adopted when it
arrives, crossfading the canvas. Item detail and the expanded player also make their first
selection provisional while it is neutral (`adoptsLatePaletteOnArrival`). Extraction is cache-only
and can finish after the page opens, and on a cold launch the saved row is often written by
another surface moments later. A palette present on the first frame is still final, so a settled
page is never recoloured; only a neutral one adopts.
The reader retains its independent theme override. See the 2026-09-06 appearance plan (private,
`plans/app-owned-ambient-appearance-2026-09-06.md`), which supersedes
ADR 0005's artwork-pole and night-depth rules. Cards and headers — Home shelves, the podcast show header, and editorial surfaces —
take the `CoverWash` bands, deliberately muted so a grid of tiles does not become a grid of posters.
The test for a new surface is whether it fills the whole page behind the content or sits as a
bounded tile inside a page with its own background: full page takes the ambient rule; bounded tile
takes the `CoverWash` bands.
Both rules read one saved row per cover. One `CoverPaletteService` per account, created in
composition, serves Home's cards (through `HomeWashProvider`), the players, item detail and the
background writers (`CoverPaletteBackfill`, `FollowedShowArtworkWarmPass`), so a colour any of them
resolves reaches the others. It is the only reader and writer of the row, and it applies the rules
in `CoverPaletteWriter`: which row answers, which cached bytes are the source, when a visible request
may join a display fetch, and what the row holds. Cards follow the row as pages do: a card still on
its neutral wash adopts a row another surface saves later, and a coloured card is never recoloured.
A surface whose item has not loaded asks under a provisional identity, which may show a saved row
but never writes one. The players and item detail read by item (`palette(forItem:)`): the colour for
whichever identity that item's surfaces last asked for, so the expanded player opens on the
mini-player's answer while its own item loads. The Add Feed directory page extracts through the
service too, under the same admission, but its preview is never saved or kept. See the private plans
`plans/single-palette-pathway-plan.md` and `plans/palette-service-consolidation-plan.md`.

## 7. Error handling and resilience

- Ordinary API responses are admitted through `URLSession.bytes(for:)`: a supplied
  `Content-Length` is checked first and a bounded accumulator enforces the 25 MiB cap before full
  response materialisation or JSON decode. Selected lists/text fields use bounded helpers;
  synthesized fields are not globally size-bounded. Required top-level shape/identity is validated,
  and no raw value or body is logged.
- Retry uses capped exponential backoff with jitter. A 401 performs at most one serialized refresh
  and one resource retry before entering non-destructive re-authentication state.
- The outbox is the durability contract for server-bound user state. Cancellation, retry,
  dead-letter, acknowledgement, and crash recovery are explicit states.
- Each account has one stable local client UUID so equal-timestamp conflict outcomes survive
  relaunch. Server progress uses a distinct sentinel origin.
- [SECURITY.md](SECURITY.md) governs transport, credentials, untrusted files, and deletion;
  [API-CONVENTIONS.md](API-CONVENTIONS.md) governs request behavior.

## 8. Decision log

IDs are stable because source comments cite them, so an entry is never renumbered or deleted — not
every ID is cited today (D24, D26, D37 and D39 currently are not), but the numbering has to stay
fixed for the ones that are. Superseded entries remain short pointers rather than carrying the full
experiment transcript. Plans and owner-decision ids (`WSA-OD11`) cited in entries are private
working documents and are not published; each entry states its decision without them.

This is the *global* `D<n>` series. Several plans under `plans/` run their own `D<n>` series that
overlaps these numbers; see “Decision IDs” in the private documentation index (`docs/README.md`)
before resolving a bare `D<n>` found in a source comment.

| ID | Date | Decision | Rationale / status |
|---|---|---|---|
| D1 | 2026-07-20 | Use GRDB instead of SwiftData | Deterministic background persistence and macOS-host tests |
| D2 | 2026-07-20 | Keep the hand-maintained Xcode project; no XcodeGen/Tuist | Buildable folders plus the local package avoid another generator |
| D3 | 2026-07-20 | Put Readium behind an App-owned EPUB boundary | Keeps Core renderer-independent and testable |
| D4 | 2026-07-20 | Keep wire DTOs and database records separate | Insulates the local schema from server-shape drift |
| D5 | 2026-07-20 | Make SyncEngine the sole post-login API orchestrator | Centralizes mutation ordering and request policy |
| D6 | 2026-07-20 | Store the app-owned bounded reading position locally; sync the normalized fraction and an optional complete CFI | A partial CFI is dropped, so only a complete `epubcfi(...)` reaches `ebookLocation`. An inbound server CFI is retained as server state but is never used to restore: restore prefers the local position and falls back to the server fraction, which keeps Readium types out of Core persistence |
| D7 | 2026-07-20 | Use a hand-written API client | The published API description is incomplete/stale |
| D8 | 2026-07-20 | Use GRDB directly | Avoids an extra persistence abstraction dependency |
| D9 | 2026-07-20 | Defer Socket.IO | Pull refresh is the correctness path; sockets add dependency and lifecycle cost |
| D10 | 2026-07-20 | Set the supported ABS floor to 2.35.1 | Fixtures and source verification target that release |
| D11 | 2026-07-20 | Support one active server/user | Keeps credential and local-data ownership unambiguous |
| D12 | 2026-07-20 | Expose one composed foreground `ABSClient` | Auth, redaction, refresh, and request gating cannot be bypassed |
| D13 | 2026-07-20 | Spike `AVQueuePlayer` before freezing the adapter | Preserved the pure timeline while testing platform behavior |
| D14 | 2026-07-21 | Keep a session open while background audio is playing | Closing would stop legitimate listening-stat capture |
| D15 | 2026-07-21 | Own `NetworkConditions` and `AppLifecycle` boundaries in SyncEngine | Core needs signals without importing Network/UIKit |
| D16 | 2026-07-21 | Keep bounded diagnostics in Persistence | Diagnostics are account-owned data with deletion obligations |
| D17 | 2026-07-21 | Treat 2.35.1 as a testability floor, not first API capability | Avoids unsupported compatibility claims |
| D18 | 2026-07-21 | Enforce layering with tests as well as manifests | SwiftPM alone does not prevent every same-package import |
| D19 | 2026-07-22 | Provisionally select `AVQueuePlayer` | Simulator spike found no correctness failure; later hardened by D37 |
| D20 | 2026-07-23 | Play completed downloads as local sessions | Avoids mixed local/server progress semantics |
| D21 | 2026-07-23 | Allow the audio adapter to play validated app-container files | Enables offline playback without arbitrary URL execution |
| D22 | 2026-07-25 | Try an inset sheet and unresolved source zoom for the player | Superseded by D23, D24, D26, then D28; see archived mini-player plan |
| D23 | 2026-07-25 | Try a full-height sheet with a presenter underlay | Superseded; the sheet still exposed an inset status-bar strip |
| D24 | 2026-07-25 | Move the player to a full-screen cover with scoped drag | Presentation retained in D28; the first drag implementation was replaced |
| D25 | 2026-07-26 | Add an App-owned prepared-artwork/prefetch pipeline | Removes repeated decode and first-frame artwork gaps within fixed request caps |
| D26 | 2026-07-26 | Retry the system sheet for dismissal ownership | Superseded by measured evidence in D28 |
| D27 | 2026-07-26 | Use SwiftUI's native list section index | Avoids duplicating hit testing, compact layout, and accessibility |
| D28 | 2026-07-26 | Use a full-screen player cover with full-bleed canvas and page-owned dismissal | Full-bleed canvas retained by D39; the SwiftUI drag and its measured boundary were replaced |
| D29 | 2026-07-26 | Let palette work join the artwork fetch | Prevents a one-shot cache miss from leaving permanent neutral color |
| D30 | 2026-07-29 | Use one media-neutral local listening queue owned by the player | Up Next is playback state, not podcast navigation. An active smart list plays before it ([ADR 0016](adr/0016-active-smart-list-plays-before-up-next.md)) |
| D31 | 2026-07-29 | Persist chapter snapshots for local playback | Downloaded books retain chapter navigation and timers |
| D32 | 2026-07-31 | Pin Readium 3.11.0 in App; exclude OPDS and LCP | Keeps catalog/DRM outside Whirr's scope and Readium out of Core |
| D33 | 2026-07-31 | Guard non-trivial local ebook progress from near-zero server overwrite | Mirrors the audio reset-protection principle with ebook thresholds |
| D34 | 2026-08-03 | Add `CoreSupport` as a dependency-free domain floor | Gives shared concurrency primitives a testable home without false domain edges |
| D35 | 2026-08-03 | Use `TabView(.sidebarAdaptable)`, not `NavigationSplitView` | One native compact/regular structure matches navigation and player hosting |
| D36 | 2026-08-07 | Share one shell-lifetime editorial-wash coordinator | Canonical identity, coalescing, and bounded extraction prevent per-screen fan-out |
| D37 | 2026-08-07 | Harden D19's `AVQueuePlayer` selection from 2026-08-04 hardware evidence | Boundaries, rate, seek, and audible behavior passed on device; single-player replacement remains only a future fallback |
| D38 | 2026-08-10 | Expose five generic Siri voice actions through in-app App Intents and App Shortcuts | Stable iOS 26 APIs need no extension or entitlement; a weak process bridge binds only the current account's AppModel playback facade, generic metadata avoids library disclosure, and native system controls provide Liquid Glass discoverability |
| D39 | 2026-08-18 | Give the expanded player a UIKit-owned interactive dismissal | A SwiftUI drag cannot arbitrate with the page's scroll view: both recognizers claimed the pull, so a per-surface measured boundary was needed to keep controls usable and a drag begun mid-scroll still fought the content. `UIGestureRecognizerDelegate` states the precedence directly, and `UIPercentDrivenInteractiveTransition` makes cancellation a first-class state instead of a spring back to a page already tearing down |
| D40 | 2026-08-02 (recorded 2026-08-19) | Retain the custom playback scrubber rather than adopting `Slider` | Its engage threshold, speed-varying precision, and grab feedback are intentional behaviour, and its adjustable accessibility action is the deliberate VoiceOver affordance |
| D41 | 2026-09-06 | One account, several server addresses | Token and account-fence identity move from the server URL to a credential namespace so LAN, tailnet, and public addresses of one server stay one account with its downloads and progress; a new address is proved by the stored token against `/api/me`, never by its URL; selection is concurrent with a two-second preference window and never switches mid-playback or mid-transfer |
| D42 | 2026-09-10 | Let the engine's observed extent grow a declared duration that under-ran it, and let only the skip intent finish an item by running past its end | Podcast feed and ABS manifest durations are routinely derived from a stale MP3 header that predates a dynamically inserted advert, so the audio outruns the number. The timeline clamped every reported position to the declared end, freezing the playhead at "0:00 remaining" over audible audio and landing a skip forward back on the advert's first frame. Correction is grow-only and single-track. Completion is carried by an explicit `PlayerIntent.skip(by:)` rather than inferred from a seek's magnitude: `PlaybackModel.play` resumes by seeking to a stored position, and such a position can legitimately sit past a declared duration that under-ran — routed as a skip it would finish the episode the listener asked to resume. The over-running position is sent to `/sync` unclamped: the server marks progress finished when `duration - currentTime` falls below its per-library `markAsFinishedTimeRemaining` (default 10s), which already fired at the declared end before this change, and its stored `progress` is clamped to 1 — so clamping the wire value would preserve the early finish while discarding the only correct position |
| D43 | 2026-10-06 | Add `AdSkip`, a dependency-free target for the pure podcast ad-skip pipeline | The frozen repetition, arbiter and learned-store rules must reproduce the off-repo harness exactly, so they live in a Foundation-only target testable on macOS and importable by the harness's parity run. It owns no records and no I/O: Persistence keeps the rows without importing it, the App supplies transcription, silence detection and scoring through its protocols, and AppModel's coordinator is its only package consumer (private plan `podcast-ad-skip-plan.md`, OD1). Amended 2026-11-15: `EpisodeTranscriptCoordinator`, the listener's transcript, is a second AppModel consumer, and `TranscriberGate` gives the two one recogniser at a time (transcript plan §4). Amended 2026-11-17: `LookBackCoordinator`, an audiobook's last minutes as text, is a third, served first at the gate; it holds the gate for a whole run and asks a running transcript to yield (Look Back plan §4.4) |
| D44 | 2026-10-07 | Drive the player's interactive dismissal from an owned `UIViewControllerInteractiveTransitioning`, not `UIPercentDrivenInteractiveTransition` | The percent-driven transition resumes the animator's own curve from wherever the finger lets go, so the page changed speed on release. `PlayerInteractiveDismissal` scrubs the same interruptible animator linearly and continues it with a critically damped spring whose initial velocity is the finger's (`PlayerDismissalPolicy.releaseVelocity`). The non-interactive slide moved from a duration-fitted spring to an eased cubic over `slideDuration`, and the page is rasterised for the duration of any transition because the in-motion corner mask otherwise forces an offscreen pass per frame. D39's gesture arbitration is unchanged |
| D45 | 2026-10-08 | Let a sponsor phrase move a kept ad range's start, gated by the phrase and a 90 s cap as well as the arbiter | The sponsor's name is the word the transcriber spells least consistently, so no shingle matches it and a matched range starts after the lead-in. `SponsorPhraseStart` (in `AdSkip`, applied by the coordinator after learning, like `PlaybackEdges`) moves the start back to a strict-form phrase ("this episode is brought to you by", "a word from our sponsors") at most 90 s before the range. It never creates a range, never moves an end, and is not learned. The extended range must still pass the arbiter, but programme bridges score up to 0.13 on the tuning roots, so the phrase form and the cap are a deliberate second gate rather than the arbiter being the single one (private plan `podcast-ad-skip-lead-in-plan.md` §4.3) |
| D46 | 2026-10-29 | Let a sponsor phrase straight after a recurring break sting create a playback-only range with no arbiter veto | A sponsored segment can be a one-off read several minutes long, so it matches nothing and opens beyond `SponsorPhraseStart`'s 90 s cap. The arbiter scores such a segment's body as programme, and the body is never transcribed. `StingSegment` (in `AdSkip`, applied by the coordinator after learning) skips from a short recurring run to the next kept range or sting when a strict-form phrase starts within 2 s of the run's end, and drops a segment with no end within 360 s. The gate is the sting and the phrase together, plus the cap. The range is never learned, and Undo tombstones it (private plan `podcast-ad-skip-sting-segment-plan.md`, SS-OD3) |
| D47 | 2026-10-30 | Let another show's audio pass the arbiter's veto, and fill a gap of up to 60 s between two served ranges, both playback-only | A cross-promo or a host-voiced read scores as programme, so the arbiter drops it, though the same audio plays in another show's episode. `CrossShowEvidence` (in `AdSkip`, applied by the coordinator) keeps a dropped candidate when one stage-1 alignment with an episode of another show covers 15 s of it. A show is its source, account and item, joined by linked copies and the feed fingerprint. A rerun in the episode's `EpisodeGroups` group, and a learned creative, are not evidence. Its audio-edge moves skip the arbiter only where such an alignment covers them (BF-OD7). `PlaybackEdges.breakFills` serves a gap of more than the player's 9 s join and at most 60 s between two served spans, unless the gap holds a tombstoned shingle. Neither rule's ranges are learned. Undo of a fill takes the joined skip with it (private plan `podcast-ad-skip-break-fill-plan.md`, BF-OD2, BF-OD3, BF-OD4, BF-OD12) |
| D48 | 2026-11-04 | Bind each account-lifetime `ABSClient` to one account at construction | A client outlives removal and endpoint switches in anything that retains it, and an unbound one re-reading "the current account" would send the next account's bearer and refresh token to the old server. Binding answers "can this object send account X's credentials?" where the object is built, so it needs no removal step (no `retire()`, ACR-OD5) and covers endpoint-switch orphans. The refusal is `APIError.cancelled`, so server-save convergence stops and the outbox requeues without dead-lettering; the bound outbox requester returns before any row write. A refresh persists only over a pair still stored (`abs-client-account-retirement-plan.md`, ACR-OD1–OD5) |
| D49 | 2026-11-06 | Add `WidgetProtocol`, a dependency-free leaf shared by the app and the widget extension | The extension's only input is a snapshot file in the App Group, so its values, codec, paths and the Live Activity attributes need one home both targets link. A leaf keeps the extension off `AppModel`, `Persistence` and `ABSApi`, and its pure validation is tested on macOS. ActivityKit is guarded to iOS ([ADR 0014](adr/0014-widget-shared-values-live-in-a-package-leaf.md), widgets plan WLA-OD7 (a)) |
| D50 | 2026-11-06 | Feed the widget extension a published snapshot and resolve its actions in the app | The extension reads one bounded file and the covers beside it, and holds no account, so it cannot reach the network, Keychain or database. `WidgetRuntime` owns the publisher for the process lifetime, independent of the Watch; `WidgetSnapshotAssembly` is its pure core and `WidgetFileStore` its only file access. Rows carry opaque per-binding tokens that only the app's token map resolves, so an intent names no server identity and a stale token starts nothing. Stats are the stored snapshot's dated days, and the extension derives today and the streak at render time, so publishing never fetches (LS-OD4). The sleep-timer Live Activity is driven by `SleepTimerActivityDriver` from `PlaybackHardware`, behind a sink tests replace. A widget or Live Activity tap arrives as a `whirr://widget/…` link (`WidgetTapDestination`) that `RootView.onOpenURL` resolves through `WidgetTapRouter` and the same token map once the library shell is mounted; a link only navigates (widgets plan, WLA-OD3, OD6, OD10; tap destinations plan, WTD-OD1; SECURITY.md rules 10 and 21) |
| D51 | 2026-11-13 | Carry the learned-ad signature store in the podcast backup file, as an optional section under snapshot version 1 | A reinstall wipes the store, which takes weeks of listening to rebuild. `NativePodcastBackupContents.LearnedAd` (owned by `Persistence`, no `AdSkip` import) crosses to `SyncEngine`, whose `PodcastLearnedAdsSnapshotCodec` writes hashes packed and prints zlib-compressed, inside a 24 MiB budget that drops prints, then ads, least recently seen first, and never fails the backup. Older builds ignore the key. Restore fills in by content (kind and hash set), keeps the later `lastSeen`, and translates RSS teachers through the file's own shows; server teachers are dropped. A print-format string from `AudioPrint`'s parameters drops prints another algorithm wrote. `AppModel` leaves out ads past the 90-day expiry and tells `AdSkipCoordinator` after a restore, which re-reads its prints and recomputes. iCloud sync of the store is parked (private plan `podcast-ad-skip-learned-ad-backup-sync-plan.md`, LAB-OD1 to OD6, OD12; SECURITY.md rule 20) |
| D52 | 2026-11-13 | Store each learned ad once, with every episode that taught it | The store kept one copy of an ad for each episode that carried it: 631 ads for about 140 on the owner's phone, which filled the hash cap and made the backup 15 MB. `LearnedAdMerging` (in `AdSkip`) decides when two learned ads are the same (80% of the smaller hash set and of the shorter print) and merges them; an ad matches an episode unless every teacher is in that episode's group. `LearnedAdDraft` (in `AppModel`) is the store as one pass leaves it: the loaded rows collapsed, then learning, written once through `AdSignatureStoreChange`, which gained additions to an existing ad. Restore treats a file ad as present when a local ad contains its hashes. No migration: the stored copies collapse on the next pass |
| D53 | 2026-11-17 | Treat the phone and the Watch as peers; retire the playback lease | The lease made the Watch's right to play depend on a phone that was often asleep or out of range, so starts were refused or stranded and a cleared journal could fence a device for good. Each device now plays locally and writes its own progress; the newest listen settles a conflict (R11). Before starting, a device asks the other to pause only when it reports playing: the Watch waits up to 3 s for the position of the same title and sends a fire-and-forget request for another. The Watch publishes a playing report in its application context, which expires after 3 minutes. Continue on iPhone sends `.play` with the paused position, which the phone uses in place of its own lookup, and unloads the Watch only once the phone accepts. The Watch never opens a server playback session (WPX-OD1). The old keys, journals and defaults are deleted on launch (watch playback extraction plan §4, WPX-OD1, OD3, OD11, OD13, OD14; ADR 0003 amendment) |
| D54 | 2026-11-17 | After the Watch takes a title the phone has loaded, the phone's next play of it is a start | A resume of the loaded title played from the phone's stale position, and the Watch asks the phone to pause only when the phone plays, so a handoff from a paused phone went unseen. The phone now treats a Watch report naming its loaded, paused title, newer than its own last listen, as a takeover, as it does a pause the Watch asked for: it closes its session at once, so a later close cannot overwrite the Watch's upload, and its next play goes through `start`, which asks a playing Watch for its position (waiting up to 3 s) and opens a session carrying the server's position. Narrows WPX-OD14 (b): other resumes stay fire-and-forget. Approved by Rhys, 2026-11-17 |
| D55 | 2026-11-17 | Now Playing on the Watch shows whichever device listened last when neither is playing | R24 showed the phone whenever it reported a paused title, so pausing on the Watch switched the screen to the phone's older position. The phone now publishes its own last listen to its loaded title on that row (an optional `lastListenedAt`, stamped only by progress events that carry listening, in memory), and the Watch weighs it against its own: a playing device still wins, then the later listen, with a phone that sends none counted as older and a tie going to the Watch. Amends R24. Approved by Rhys, 2026-11-17 |
| D56 | 2026-11-18 | The Watch offers one move to the Watch when the phone is shown, not "Resume on Watch" beside "Move to Watch" | With the phone on screen and a paused Watch title still loaded, both buttons ended with the Watch playing and the phone paused; "Resume" kept the Watch's older position and "Move" took the phone's, which the focus rule makes the newer listen. Only "Move to Watch" remains (or "Play on Watch" when the phone is unreachable, R27, now also with a Watch title loaded); the Watch-only "Resume" on the player and detail views is unchanged. Amends R24, WPX-OD12. Approved by Rhys, 2026-11-18 |
| D57 | 2026-11-21 | The iPhone sends Audiobookshelf books and episodes to the Watch as a desired set, and On Apple Watch lists everything the Watch holds | Send to Watch existed only for followed RSS episodes. The phone now publishes a separate `WatchABSSendOffer` (no URL, token or file list) and the Watch plans and downloads with its own sign-in on its existing per-account session, so no new traffic class or credential path. Each ABS download group carries an origin: omission removes only phone-origin groups, a Watch-origin group goes only through the offer's explicit `removals`, and the phone never adopts one. Both ends fence by account stamp; after a sign-in the phone sends nothing until a matching stamped inventory arrives, then re-adopts its phone-origin entries, so signing out and back in removes nothing from the Watch. Phone state is the account-owned `absWatchCopy` table behind one `WatchCopies` front over the RSS and ABS models. Wire stays at version 1 with optional fields only, and capability `absSend` gates sends ([ADR 0021](adr/0021-iphone-sends-audiobookshelf-items-to-the-watch.md); watch-send-all plan, WSA-OD1 to OD14). Approved by Rhys, 2026-11-21 |

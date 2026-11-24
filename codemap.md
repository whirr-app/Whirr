# Code map

Whirr has iOS and watchOS application shells around one local Swift package. Put domain,
persistence, sync, and testable view-state behavior in `Packages/Core`; keep SwiftUI composition
and platform adapters in `App/Whirr` and `App/WhirrWatch Watch App`.

For governing rules, start with the documentation index (`docs/README.md`, a private record); the
exported contracts are [ARCHITECTURE.md](docs/ARCHITECTURE.md) and its siblings in `docs/`. This file
answers only “where does the code live?” and deliberately carries no project status.

## Dependency direction

```text
App → AppModel → SyncEngine → Persistence / ABSApi / CoreSupport
App → AppModel → PlayerCore / ReaderCore / PodcastFeeds / AdSkip / Persistence / CoreSupport
ReaderCore → CoreSupport · PodcastFeeds → ABSApi / CoreSupport · Persistence → GRDB
ABSApi, PlayerCore, AdSkip, CoreSupport → no package dependencies
App → DesignSystem · App/Whirr/AdSkip adapters → AdSkip
Watch App → WatchPlayback → ABSApi / PlayerCore / WatchProtocol
iPhone App → AppModel + App/Whirr/Watch adapters → WatchProtocol
iPhone App → App/Whirr/Widgets adapters → WidgetProtocol · Widget Extension → WidgetProtocol
App/WatchShared → compiled into both App targets
```

`CoreSupport` is the domain-free floor. `DesignSystem` is UI-only and consumed by the app.
Production targets never import `TestSupport`. Exact allowed dependencies and exceptions are in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Change routing

| Change concerns | Primary location | Useful entry points |
|---|---|---|
| Domain-free concurrency/tracing utilities | `Packages/Core/Sources/CoreSupport/` | `AsyncEventMulticaster.swift` (subscriber fan-out for a multi-consumer stream; the App's playback, background-transfer and preference stores use it), `DeviceTraceLog.swift` |
| HTTP, auth, request policy, endpoints, wire DTOs | `Packages/Core/Sources/ABSApi/` | `HTTPTypes.swift` (request/response values and the URLSession client), `HTTPRedirectPolicy.swift`, `HTTPResponseBody.swift`, `AuthenticatedHTTPClient.swift`, `RequestPipeline.swift`, endpoint-named files (`PodcastArtworkHostPolicy.swift` holds the public-artwork-host rule for podcast writes) |
| RSS/Atom feed fetch and parse, OPML, podcast directory search | `Packages/Core/Sources/PodcastFeeds/` | `FeedFetchClient.swift`, `FeedParser.swift`, `OPML.swift`, `PodcastDirectorySearch.swift`, `RSSArtworkClient.swift` |
| SQLite schema, records, DAOs, observations | `Packages/Core/Sources/Persistence/` | `AppDatabase.swift`, `Schema/` (`SchemaV1.swift` holds the migration enums and the ordered `migrator()`; registrations are `SchemaV1+Era*.swift`; DDL builders are grouped by table family in `SchemaV1+DDL*.swift`; the v4 drift heal is `SchemaV1+DriftHeal.swift`), read boundaries one file per protocol family (`LibraryReading.swift`, `DownloadReading.swift`, `PodcastReading.swift`, `HomeReading.swift`; small ones in `PersistenceBoundaries.swift`), `SearchSQLFunctions.swift` (the SQL functions every connection installs), `DAOs/`, feature reading/store files |
| Podcast ad skip: pure pipeline and store policy | `Packages/Core/Sources/AdSkip/` | Foundation only, a port of the frozen ad-harness rules; `SignatureStore.swift` holds the store policy and `LearnedAdMerging.swift` the rule that stores each learned ad once (D52); `AudioPrint`, `AudioRecurrence`, `TranscriptionWindows` and `TranscriptViews` decide which seconds are transcribed; `HostReadSpans` proposes host reads from a listener's whole transcript (THR.1); `ListenerMarks.swift` lays the listener's marks over the other ranges and builds the confirmed ad a mark teaches (TRM.2) |
| Podcast ad skip: tables, store, transcript files and local episodes | `Packages/Core/Sources/Persistence/AdSkip*.swift`, `AdSignatureStore.swift` | v73 `AdSkipMigration`, v80 adding audio prints and creative prints; transcripts and audio prints are backup-excluded files, never rows; `AdSkipLocalEpisodeReader` derives analysable files from both download spines |
| Learned ads in the podcast backup file | `Packages/Core/Sources/Persistence/NativePodcastBackupLearnedAds.swift`, `SyncEngine/PodcastLearnedAdsSnapshot.swift` | reader and fill-in restore of the signature store, and the teacher key format; the optional `learnedAds` snapshot section with its caps, byte budget and single compressed blob (D51); `PodcastBackupLearnedAds` in `AppModel/PodcastBackupModel.swift` names the print format and applies the expiry |
| Podcast ad skip: speech, decoder (silences and audio prints) and scorer adapters | `App/Whirr/AdSkip/` | `SpeechEpisodeTranscriber` (windowed), `AudioFileAnalysisDecoder`, `ArbiterStepScorer`, `SpeechAssetInstaller`; the bundled `ArbiterClassifier.mlmodel`; settings UI (`AdSkipSettingsView`, `AdSkipSettingsModel`), `AdSkipBackgroundAnalysis`, `AdSkipMeasurement`, `AdSkipReceipt`; `AdSkipCardStatus` is the episode card's status line |
| Podcast ad skip: analysis queue, recompute and learning | `Packages/Core/Sources/AppModel/AdSkipCoordinator*.swift`, `AdSkipPlanBook*.swift` | One worker actor fed by `AdSkipLocalEpisodeReader`, the setting and the analysis conditions; `+Recompute` runs the library recompute as named phases; `+Queue` picks the next work unit (decodes and window transcriptions), `+Worker` runs one pass (`reconcile`) and decides what follows a unit; `AdSkipActivityPublisher` (actor-confined, reached as `activity`) settles what the glyph and status read, and `AdSkipSettledState.standing(of:)` is the status rule the card and player share; `+Undo` applies the player's and the transcript's undos; `AdSkipPlanBook` (actor-confined, reached as `plans`) holds the audio library, the stage-one and stage-two plans and their invalidation, with `+StageOne` keeping only the coordinator's retry on unreadable prints, and `+Windows` performs the work; `+EpisodeStatus` answers the episode card for any downloaded episode; composed once per launch by `App/Whirr/AdSkip/AdSkipComposition.swift`; `+HostReads` adds host-read ranges from a complete listener transcript, read through `CompleteEpisodeTranscriptReading` (THR.2); `+TranscriptRanges` serves the transcript view's ranges with their origin, its immediate undo (TRM.1) and whether marking is offered (TRM.3); `+ListenerMarks` queues the listener's marks, applies them on the worker beside recompute, and removes them (TRM.2) |
| Podcast transcripts: listener-requested sessions, the shared recogniser gate and the reading model | `Packages/Core/Sources/AppModel/EpisodeTranscript*.swift`, `TranscriberGate.swift`, `TranscriptParagraphs.swift`; `App/Whirr/Transcript/` | `EpisodeTranscriptCoordinator` runs one paced, holdable session at a time, checkpoints, resumes with a join repair and sweeps its `Transcripts` root; `TranscriberGate` serialises it with ad skip's transcriber; `SpeechTranscriptSession` and `TranscriptFeedPacer` are the App adapter; composed by `TranscriptComposition`; `TranscriptDebugTrigger` (Debug) requests and measures the loaded episode; `TranscriptParagraphs` turns words into sentences and paragraphs and `EpisodeTranscriptModel` is the sheet's state, following, seeking and search; `EpisodeTranscriptSheet` and `PlayerTranscriptController` (the player's overflow entry and `playerTranscriptSheet` modifier) draw it; `TranscriptAdBlock` draws an ad's header, rule and VoiceOver label (TRM.1); `TranscriptAdMarking` (Core) holds the availability and the two-tap selection rules, and `TranscriptAdMarkingBar` draws the Mark an ad menu, bar and VoiceOver actions (TRM.3) |
| Smart Lists: rule-built episode lists across native and Audiobookshelf shows | `Packages/Core/Sources/Persistence/SmartList*.swift`, `SyncEngine/SmartList*.swift`, `AppModel/SmartList*.swift` | v95 `SmartListMigration`; `SmartListEpisodesReading` (one SQL union of both sources, twins collapsed, keyset `nextEpisodes`); `SmartListShowExpansion` keeps named Audiobookshelf shows fully expanded (a stage of `App/Whirr/PodcastBackgroundRefresh.swift`); auto-download is `SyncEngine/SmartListDownloadReconciler.swift` over `SmartListDownloadStore` (`smartListDownloadClaim` claims, `smartListDownloadDecline` hand-removal declines from v100), and the listener's hand actions pass through `SmartListDecliningDownloadIntents` so a removed episode stays removed; the run that plays before Up Next is `PlaybackContinuationSource` / `SmartListContinuation` and `PlaybackModel+SmartListRun.swift` (ADR 0016); the backup section is `SyncEngine/PodcastSmartListsSnapshot.swift`; lists are device-local |
| Download Up Next: keeps Up Next downloaded | `Packages/Core/Sources/SyncEngine/QueueAutoDownload.swift`, `Persistence/ListeningQueueStore+DownloadDeclines.swift`, `SyncEngine/UpNextDecliningDownloadIntents.swift` | `QueueAutoDownload` requests on queue writes and `QueueAutoDownloadReconciler` on foreground and Wi-Fi return, over `ListeningQueueStore.fetchQueueIdentitiesWithoutDownloads`; a hand removal flags the entry's `downloadDeclinedAt` (v101) through `UpNextDecliningDownloadIntents`, so it stays removed until the entry leaves Up Next or is downloaded again by hand |
| Portable podcast cloud identities/merge | `Packages/Core/Sources/SyncEngine/PodcastCloud*.swift` (coordinator events: `+Events` dispatch, `+Sent` acknowledgements and conflicts, `+Fetched` admission) | mutation stamps, explicit epochs, lifecycle and acknowledgement fences; ADR 0009 |
| DEBUG Files probe | `App/Whirr/PodcastFilesDevelopmentProbe.swift` | picker-folder bookmark, bounded coordinated synthetic write/verify/replace |
| Podcast cloud sync boundary | `Packages/Core/Sources/SyncEngine/PodcastCloudSyncing.swift` | commands down, events up; `PodcastCloudActivation` carries the installation resolution |
| Podcast iCloud sync runtime (CloudKit leaf) | `App/Whirr/PodcastCloudSyncComposition.swift`, `PodcastCloudKitSyncEngineAdapter.swift` | consent-gated composition and the `CKSyncEngine` delegate; translation and keyring sit beside them as `PodcastCloudKit*.swift` |
| Native Saved-shelf resolution (replaces the `savedShelfRSSProgress` triggers) | `Packages/Core/Sources/Persistence/NativeSavedIntentResolving.swift` | resolves inside the writing transaction; `RSSEpisodeStateStore` is the only production writer of `rssEpisodeState`, enforced by test |
| Cloud-aware Saved-shelf resolution | `Packages/Core/Sources/SyncEngine/PodcastCloudSavedIntentResolver.swift` | stamps the removal and enqueues it in the writing transaction; skips the send when the cloud cannot name or stamp it, never failing the playback write |
| Podcast cloud outbox payload format | `Packages/Core/Sources/SyncEngine/PodcastCloudRecordPayload.swift` | versioned, deterministic `PodcastCloudRecordFields` blob; decoding re-validates the plaintext/encrypted split against the layout |
| Podcast cloud outbox rehydration | `Packages/Core/Sources/SyncEngine/PodcastCloudOutboxRehydration.swift` | maps the outbox's outstanding work to the sync boundary's value; the adapter seeds each new engine from it |
| CloudKit engine adapter — the only `CKSyncEngine` in the app | `App/Whirr/PodcastCloudKitSyncEngineAdapter.swift`, `App/Whirr/PodcastCloudKitTranslation.swift` | `CKSyncEngineDelegate` plus record/batch/error translation; no policy |
| API↔database orchestration, pulls, outbox, conflicts | `Packages/Core/Sources/SyncEngine/` | `SyncEngine.swift`, `*Boundaries.swift` (one file per concern), coordinator/policy files |
| Playback state, timeline, sleep logic | `Packages/Core/Sources/PlayerCore/` | `PlayerController.swift`, `PlayerReducer.swift` (concerns in `PlayerReducer+*.swift`), `PlaybackTimeline.swift` |
| EPUB position, preferences, reading-session logic | `Packages/Core/Sources/ReaderCore/` | `ReadingPosition.swift`, `ReaderPreferences.swift`, `ReaderTypography.swift` (the one step-to-value typography mapping), `ReadingSessionTracker.swift` |
| Reader chrome and appearance | `App/Whirr/ReaderView*.swift`, `App/Whirr/ReaderPageFurniture.swift`, `App/Whirr/ReaderTypographySample.swift` | system toolbar controls, running header and footer, the appearance half-sheet and Customise page with its live sample; DesignSystem `ReaderAppearanceControls*`, `ReaderProgressRail` |
| Observable screen state, navigation, copy | `Packages/Core/Sources/AppModel/` | `AppDependencies.swift`, `RootModel.swift`, `NavigationModel.swift`, feature `*Model.swift` files |
| Watch command/snapshot values and cache safety | `Packages/Core/Sources/WatchProtocol/` | versioned codecs, source-qualified selections, command deduplication, catalogue cache |
| Watch phone integration | `App/Whirr/Watch/` | `WatchCompanionRuntime`, `WatchPhoneBridge`, `WatchCataloguePublisher`; AppModel companion actions and catalogue projections |
| watchOS UI and background lifecycle | `App/WhirrWatch Watch App/` | `WatchCompanionStore`, `WatchBackgroundDelegate`, `ContentView` |
| Widget snapshot values, codec and presentation rules | `Packages/Core/Sources/WidgetProtocol/` | `WidgetSnapshot`, `WidgetSnapshotCodec`, `WidgetStorageLayout`, `*Presentation.swift`, `SleepTimerActivity.swift`, `WidgetTapDestination` |
| Widget publishing and the sleep-timer Live Activity | `App/Whirr/Widgets/` | `WidgetRuntime`, `WidgetSnapshotPublisher`, `WidgetSnapshotAssembly`, `SleepTimerActivityDriver`, `WidgetTapRouter`; intents in `App/Whirr/Playback/SiriPlaybackIntents.swift` |
| Widgets, controls and Live Activity views | `App/WhirrWidgets/` | `WhirrWidgetsBundle`, `WidgetSnapshotReader`, one file per widget or control |
| Reusable SwiftUI tokens and components | `Packages/Core/Sources/DesignSystem/` | `Tokens/`, `Components/` |
| Production dependency graph | `App/Whirr/AppEnvironment.swift` | database, clients, coordinators, readers, and app-model composition; per-concern compositions beside it (`AppEnvironment+*Composition.swift`, `RootComposition.swift`, `PodcastCloudSyncComposition.swift`, `PodcastBackupComposition.swift`) |
| Problem reports and local diagnostics | `Packages/Core/Sources/AppModel/ProblemReport*.swift`, `App/Whirr/Diagnostics/` | issue-form prefill, redacted diagnostics bundle, MetricKit crash/hang archive, `OSLogStore` session reader, `ProblemReportView.swift` |
| App lifecycle and root replacement | `App/Whirr/WhirrApp.swift`, `App/Whirr/RootView.swift` | launch, authentication, environment lifecycle; the app-root alerts for failures any surface can raise (`PlaybackStartFailurePresentation.swift`, `PlaybackRateWriteFailurePresentation.swift`) |
| Tabs, destinations, and screens | `App/Whirr/Views/` | One folder per screen or surface (`Home/`, `Library/`, `ItemDetail/`, `Podcasts/`, `Player/`, `Settings/`, …); `Library/LibraryShellView.swift` hosts the tabs, and `Shared/` and `Artwork/` hold what several screens use |
| CarPlay (on `main`, for R1; rendered on a tethered iPhone, see the plan's CP3 platform record; CP5 and CP6 open) | `Packages/Core/Sources/AppModel/CarPlay*.swift`, `App/Whirr/CarPlay/` | Core: `CarPlayBrowseModel`, `CarPlayPlaybackActions`, `CarPlaySelectionOperations`, `CarPlayNowPlayingControls`, `CarPlayPresentation` (navigation budget, list capacity, feedback), `CarPlayPagedList`, `CarPlayEpisodeDetail`, `CarPlayArtworkRequests`; Persistence: `AudioEntityPaging` (authors and series from audiobook items). App: `CarPlaySceneDelegate`, `CarPlayCoordinator`, `CarPlayEnvironment`, `CarPlayListContent`, `CarPlayInterface` |
| iOS-only media/download/lifecycle adapters | `App/Whirr/Playback/`, `Downloads/`, `Lifecycle/` | AVFoundation, background URLSession, network/lifecycle bridges |
| Voice Boost (speech-clarity effect) | `App/Whirr/Playback/VoiceBoost*.swift`, `App/Whirr/Views/Player/VoiceBoostCopy.swift` | `VoiceBoostDSP` (the signal chain), `VoiceBoostTapFactory`/`VoiceBoostTapState` (the `MTAudioProcessingTap` on each item), `VoiceBoostPreferenceObserver` (preference to engine); attached by `AVQueuePlayerAudioEngine.makeConfiguredItem` and `setVoiceBoostEnabled` |
| EPUB renderer adapter | `App/Whirr/ReadiumEPUBRenderer.swift` | Readium translation and lifecycle |
| Serverless UI scenarios | `App/Whirr/UIHarness*.swift` | `UIHarnessScenario` resolves `WHIRR_UI_HARNESS_*` and `UIHarnessSession` holds one `RootComposition` (in-memory store, setup graph) plus the simulated audio stack; each `UIHarness+<Screen>.swift` supplies that screen's fixture reads. `UIHarnessReleaseExclusionTests` proves the Release gate |
| Debug and performance probes | `App/Whirr/HarnessProbeEvent.swift`, `MicrostutterProbe.swift`, `UIHarnessScrollProbe.swift` | `perfNote` counts one named site and compiles to nothing without `PERF_INVESTIGATION`; `harnessNote` records a `HarnessProbeEvent`; `harnessTimedSpan` times a span. `ViewSourceScan` ignores both `perfNote` lines and `#if PERF_INVESTIGATION` blocks |

Wire DTOs are declared in `ABSApi`; database records are declared in `Persistence`; `SyncEngine`
owns mapping/orchestration between them. SwiftUI screens bind to `AppModel` and persisted
projections rather than rendering network responses directly.

## Feature trails

- **Home, Library, Search, detail:** ABSApi endpoints → SyncEngine refresh/search → Persistence
  readings → `AppModel` feature models → matching views.
- **Playback:** session endpoints/resources → `PlaybackSessionCoordinator` → `PlayerCore` →
  `PlaybackModel` → App playback adapter and `Views/Player/`.
- **Downloads/offline:** authorized download requests → `DownloadCoordinator` (`+Intents` user
  actions, `+Purge` purge and account removal, `+TransferScheduling` slot admission,
  `+TransferStart`, `+TransferEvents` adapter events) → persistence/file stores → download/storage models → App background-session adapter and views. Automatic retry of
  failed automatic rows: `AutomaticDownloadRetryPolicy` (SyncEngine; cap, backoff, classification)
  → `DownloadCoordinator+AutomaticRetry.swift` (armed at the failure sites, swept at the start of
  each schedule pass) → `DownloadStore+AutomaticRetry.swift` and `RSSDownloadStore+AutomaticRetry.swift`
  (Persistence; `autoRetryCount`/`autoRetryNotBefore`, v79).
- **Podcasts:** podcast readings/refresh/auto-download coordinators → podcast models and universal
  listening queue → Podcasts, show, episode, and player surfaces.
- **EPUB:** ebook download/persistence → `ReaderCore`/`ReaderModel` → App-only Readium adapter →
  `ReaderView` and reader components.
- **Companion PDFs:** `ItemSupplementFiles.swift` (ABSApi, from `ebookFile` and `libraryFiles`) →
  `ExpandedItemPersistor` and `DownloadCoordinator+Planning.swift` (SyncEngine; `.supplement` rows
  planned with the audiobook, or alone via `requestSupplementDownload`) → `itemSupplement` table and
  `ItemSupplementStore` (Persistence; `DownloadMediaKind.itemMediaSQL` keeps the rows out of every
  item-level fold) → `ItemSupplementsModel` (AppModel) → `App/Whirr/Supplements/` (PDFKit viewer,
  detail row), opened from item detail and the player's overflow menu.
- **Multi-select actions (Saved for Later, Home Continue, Library Titles):** each view resolves
  `ItemBatchTarget`s → `ItemActionsModel.performBatch` (`ItemActionsModel+Batch.swift`, AppModel;
  one target at a time, a per-target `ItemBatchOutcome`) → `SelectionBatchEnding`
  (`App/Whirr/Views/Selection/`), the one selection ending all three apply. Book and episode progress
  interlocks (stop before finish, seek after reset) go through `PodcastEpisodeProgressActions`
  from every surface. A show's episode selection has its own
  `PodcastShowModel.performSelectedAction`.
- **Save a native episode to Audiobookshelf (NP12):** `NativeEpisodeServerSaveCommandReader`,
  `ServerPodcastDestinationResolver` and `NativeEpisodeServerSaveCoordinator*.swift` (SyncEngine;
  `+Flights`, `+Pipeline`, `+Preflight`, batch, reconciler, recovery, removal) → `NativeEpisodeServerSaveAttemptStore`
  (Persistence) → status projection, `NativeEpisodeServerSaveAttemptFence` (stale-snapshot filter)
  and `NativeEpisodeServerSaveLifecycleEdges` (account and subscription edges), shared by
  `PodcastShowServerSaveModel` (owned by `PodcastShowModel` as `serverSave`; state in the main
  file, `+Observation` projections, `+Actions` single save, `+Batch`, `+ShowSave`) and
  `PodcastEpisodeCardModel` (AppModel; server save in `+ServerSave`) →
  `NativeEpisodeServerSaveSheets.swift` (App). Every SyncEngine decision that infers an episode's
  absence from a show's list, refresh soft delete included, asks
  `PodcastMedia.episodeListProvesAbsence` (`SyncEngine/EpisodeAbsenceEvidence.swift`).
- **Send to E-reader:** `EbookDeliveryEndpoints.swift` (ABSApi) → `EbookDeliveryService`
  (SyncEngine) → `ItemActionsModel` and `EbookDelivery.swift` (AppModel) → the `.server` section of
  `ItemContextMenuContent` (App). No persistence.
- **Item action menus:** titles and glyphs in `MediaActionCopy`; entries as `MediaItemAction`
  sections from `BookMenuPresentation` and `PodcastShowPresentation.episodeActionSections`
  (AppModel) → rows in `ItemContextMenuPresentation+Rows.swift` and
  `PodcastShowViewPresentation.contextAction` (App) → drawn by `MediaActionMenuItems`
  (DesignSystem). `MediaItemMenuLayout` (AppModel) folds the progress entries into one submenu
  for every item menu and the player overflow; removals are the last section. The
  `item-action-titles-come-from-media-action-copy` source rule fails on a title typed out elsewhere.
- **Account lifecycle:** authentication → lifecycle/removal coordinators and account stores → setup,
  reconnect, logout, and root-model state. Server addresses: `AccountEndpointService` and
  `EndpointSelector` (SyncEngine) → `ServerAddressesModel` (AppModel) → `EndpointSwitchCoordinator`,
  `ServerAddressesView`, and `AddServerAddressView` (App).
- **Artwork/editorial presentation:** cover transport in ABSApi (`CoverImageClient` over the
  `CoverFileStore` file cache; `DetailArtworkSizing` for the item-detail width), prepared image
  coordination in App (`DetailArtwork` is the one detail-cover key), reusable card/token surfaces
  in DesignSystem. The bulk pass, its sweep and the cover-shape step are
  `CoverCacheAllCoordinator` (SyncEngine). Cover colour: `CoverPaletteService` (App, one
  per account from `AppEnvironment+ArtworkComposition`) is the only extractor, reader and writer of
  the saved palette rows; `CoverPaletteWriter` holds the rules and `HomeWashProvider` adapts it for
  Home's cards.

## Watch source map

`WatchProtocol` has no package dependencies; guarded system frameworks are permitted.
`WatchPlayback` declares the three edges above in `Packages/Core/Package.swift`; the Watch target
links those products directly and registers the shared `App/WatchShared` sources, both in
`App/Whirr.xcodeproj/project.pbxproj`. The iPhone adapters map AppModel companion selections and
projections into wire values; AppModel itself has no WatchProtocol edge, and
`App/Whirr/Watch/WatchCatalogueWireMapper.swift` is what imports both sides.

Paths below are relative to each named directory. The lists name the principal files; they are not
an exhaustive inventory.

### Watch app composition and controllers — `App/WhirrWatch Watch App/`

- `WhirrWatchApp.swift` — App entry and observable environment composition.
- `ContentView.swift` — Root navigation and Now Playing toolbar.
- `WatchCompanionStore.swift` — Phone snapshot cache, commands and browse replies.
- `WatchLibraryModel.swift` — Observable façade over five controllers.
- `WatchSessionContext.swift` — Immutable account services and cancellable lifecycle tasks.
- `WatchSessionController.swift` — Restore, install, account replacement and logout.
- `WatchCatalogueController.swift` — Library selection, paging and Continue projection.
- `WatchPlaybackController.swift` — Local playback, the pause-and-position handoff both ways, Continue on iPhone, playing report and bookmarks.
- `WatchOfflineSyncController.swift` — Peer reconciliation and offline progress upload.
- `WatchDownloadController.swift` — Download labels, grouped actions and background resume.
- `WatchBrowseModel.swift` — Shared catalogue paging, retry and request fencing.
- `WatchPhoneBrowseModel.swift` — Phone browse paging with account and request fences.
- `WatchHomeProjection.swift` — Pure phone/Watch Continue merging.
- `WatchNavigationPolicy.swift` — Media-type filtering and preferred library choice.
- `WatchDownloadGroup.swift` — Multi-track grouping and aggregate state.
- `WatchDownloadRowPresentation.swift` — Download row copy and available actions.
- `WatchCommandOutcome.swift` — Command result, feedback event and shared status copy.
- `WatchDisplayFormatting.swift` — Time, date, duration and metadata formatting.
- `WatchArtworkStore.swift` — One account-fenced, two-request artwork queue shared by rows and the player.
- `WatchArtworkSyncReceiver.swift` — Inbox for phone-pushed cover files, ingest into the synced cache tier, and want lists back.

### Watch platform adapters — `App/WhirrWatch Watch App/`

- `WatchAudioEngine.swift` — AVQueuePlayer, global seek and Now Playing controls. Applies `PlaybackTimeline.grown(toObservedLocalExtent:)` itself (D42), since it never enters `PlayerReducer`.
- `WatchBackgroundDelegate.swift` — WCSession ingress and WatchKit background completion.
- `WatchDownloadManager.swift` — Durable download actions and task/epoch-fenced events.
- `WatchDownloadURLSessionAdapter.swift` — URLSession tasks, delegates and temp-file handoff.
- `WatchSetupReceiver.swift` — Live credential admission and persisted setup receipts.
- `WatchNetworkStatus.swift` — Network path and Wi-Fi availability.
- `WatchDiagnostics.swift` — Payload-free OSLog events.

### Watch views — `App/WhirrWatch Watch App/`

- `WatchHomeView.swift` — Browse destinations and current/continued playback.
- `WatchContinueView.swift` — Continue Listening list.
- `WatchAccountView.swift` — Phone-assisted setup, settings and logout.
- `WatchDownloadsView.swift` — Grouped on-Watch downloads and progress.
- `WatchAudiobookBrowseViews.swift` — Titles, authors, series and library picker.
- `WatchPodcastServerViews.swift` — Server podcast hubs, shows and episodes.
- `WatchPodcastPhoneViews.swift` — Phone-supplied podcast lists, one source each, and the Followed on iPhone hub.
- `WatchBrowseComponents.swift` — Browse status, pagination, entity and episode rows.
- `WatchRows.swift` — Selection, phone shelf, setup and action-status rows.
- `WatchSelectionDetailView.swift` — Selection playback/download actions.
- `UnifiedNowPlayingView.swift` — Phone and Watch controls and destination selection.
- `WatchPlaybackSpeedView.swift` — Shared playback-rate picker.
- `WatchChapterListView.swift` — Chapter picker for Watch playback.
- `WatchArtworkView.swift` — Cover thumbnail view fed by `WatchArtworkStore`.
- `WatchVisualStyle.swift` — Presentation-only colours and styling.

### Phone adapters — `App/Whirr/Watch/`

- `WatchCompanionRuntime.swift` — Composition, account binding and lifecycle fencing.
- `WatchCompanionRuntime+ABSSend.swift` — Binds the account's Audiobookshelf send half with the account graph.
- `WatchCopies.swift` — The screens' one Send to Watch front, routing RSS and Audiobookshelf titles.
- `ABSWatchCopiesModel.swift` — Audiobookshelf desired set plus the Watch's own downloads, for the screens.
- `ABSWatchSendPublisher.swift` — Account-stamped Audiobookshelf offers, gated on a matching inventory.
- `ABSWatchInventoryInbox.swift` — Applies the Audiobookshelf half of a Watch inventory for this account.
- `../Views/Watch/OnAppleWatchView.swift`, `OnAppleWatchPresentation.swift` and `+Audiobookshelf` — The On Apple Watch screen: storage, Audiobooks and Episodes, from both desired sets and the Watch's own downloads.
- `../Views/Watch/BookWatchPresentation.swift`, `ItemContextMenuContent+BookWatch.swift`, `ItemDetailWatchStatusLine.swift` — A book's Watch pair in the menus' `.download` section and the detail page's one Watch line.
- `WatchPhoneBridge.swift` — Sole phone WCSession ingress and payload routing.
- `WatchPendingProgressInbox.swift` — Holds the Watch's latest pending-progress report; start gate that weighs it.
- `WatchPhoneRequestRunner.swift` — Bounded decode, stamp admission, action and keyed reply.
- `WatchPhoneCommandEndpoint.swift` — Command deduplication and phone playback admission.
- `WatchCataloguePublisher.swift` — Projection refresh and publication lifecycle.
- `WatchCatalogueWireMapper.swift` — Pure AppModel projection-to-wire mapping.
- `WatchCatalogueTransport.swift` — Latest-only context delivery and retry.
- `WatchPhoneBrowseEndpoint.swift` — Bounded phone browse request/reply endpoint.
- `WatchPhoneBrowseModel.swift` — Phone-side persisted catalogue browse projection.
- `WatchPhoneHandoffEndpoint.swift` — Answers the Watch's pause-and-position request, then flushes progress.
- `WatchPhoneHandoffAsker.swift` — Before a phone start or resume, asks a Watch that reports playing to pause.
- `WatchCommandScope.swift` — Marks playback the Watch caused, and the position it handed over.
- `../Views/Player/CompanionDeviceIndicatorPresentation.swift` — R28 "Playing on Apple Watch" copy and when it shows (on book detail it wins `BookWatchPresentation.statusLine`); the held report is `AppModel/CompanionDevicePlayback.swift` on `PlaybackModel`, set by `WatchCompanionRuntime.storePlayingReport`.
- `WatchPhoneSetupModel.swift` — Independent Watch credential provisioning on iPhone.
- `WatchSetupAttempt.swift` — Challenge/payload lifetime and retry eligibility.
- `WatchInstallState.swift` — How far the paired-Watch prerequisites have progressed.
- `WatchPhoneArtworkEndpoint.swift` — Optional, independently bounded artwork replies.
- `WatchArtworkSyncPublisher.swift` — Whole-library cover manifest and want-list answers sent as files to the Watch.

### Shared adapters — `App/WatchShared/` (compiled into both targets)

- `WatchPeerMessageSender.swift` — Bounded live WCSession request/reply bridge.
- `WatchArtworkThumbnail.swift` — Off-actor decode straight to a bounded thumbnail.

### Wire values and policy — `Packages/Core/Sources/WatchProtocol/`

- `WatchProtocol.swift` — Account stamps, selections, commands, snapshots and WatchWireCodec.
- `WatchProtocolSafety.swift` — Command deduplication, destination preference and reply gate.
- `WatchBrowse.swift` — Browse request (with its optional source), page, row and reply wire values.
- `WatchCatalogueCache.swift` — Account-fenced snapshot cache and tombstones.
- `WatchSetup.swift` — Bounded setup exchange values and admission.
- `WatchHandoffValues.swift` — ABS-only selection identity, wire limits and coarse errors.
- `WatchHandoff.swift` — Pause-and-position request and reply, the Watch's playing report, and the answering side's admission rules.
- `WatchOfflineConflictPolicy.swift` — Watch/shared position rule: newer listen wins, near-ties take the further position.
- `WatchPendingProgress.swift` — Watch→phone pending-progress report, query, and the start-position rule.
- `WatchArtwork.swift` — Cover request/reply values; revisions are opaque tokens, never URLs.
- `WatchArtworkSync.swift` — Cover-sync manifest, want-list and bundle values and their limits.

### Watch services — `Packages/Core/Sources/WatchPlayback/`

- `WatchLibraryModels.swift` — Domain library rows, pages, audio and account values.
- `WatchLibraryService.swift` — Narrow account, catalogue, playback, download and upload seams.
- `ABSWatchLibraryService.swift` — ABSClient-backed implementation of those capabilities.
- `WatchLibraryClient.swift` — Account-fenced authentication and catalogue client.
- `WatchLibraryBrowse.swift` — Bounded traversal, deduplication and browse projections.
- `WatchAccountStore.swift` — Independent account/token persistence and settings seam.
- `WatchSessionTokenStore.swift` — Invalidatable token forwarding per service generation.
- `WatchAccountFencedJSONStore.swift` — Version/stamp envelopes and atomic persistence.
- `WatchProtectedFileStore.swift` — Account-linked Watch state (record, receipt, catalogue cache, labels, bookmark) in protected, backup-excluded files; `WatchProtectedRead` tells unreadable from absent.
- `WatchAudioPreparation.swift` — Direct-play validation and global timeline preparation.
- `WatchPlaybackSessionCoordinator.swift` — Serialized local playback preparation, media renewal; never opens a server session.
- `WatchResumeBookmark.swift` — Validated account-scoped resume position.
- `WatchDownloadModels.swift` — Download manifests, states and offline-progress values.
- `WatchDownloadPlanner.swift` — Validated multi-track download descriptors.
- `WatchDownloadStore.swift` — Account-scoped manifests, quota and completed-file admission.
- `WatchDownloadFileVault.swift` — Containment, symlink, staging and byte validation.
- `WatchDownloadValidation.swift` — Shared descriptor/manifest validation.
- `WatchOfflineProgressStore.swift` — Durable local listening sessions and acknowledgements.
- `WatchLocalProgressLifecycle.swift` — Opens, closes and finishes progress rows for locally played titles.
- `WatchPendingProgressReport+Store.swift` — Builds the pending-progress report from unuploaded rows.
- `WatchOfflineReconciliationPlan.swift` — Pure reconciliation: one position per title from the conflict policy.
- `WatchUploadScheduler.swift` — When the Watch uploads: lifecycle triggers, retries at 1, 5 and 15 minutes, the 10-minute checkpoint.
- `WatchListeningClock.swift` — Listening time on the uptime clock and each title's last listen.
- `WatchResumePosition.swift` — Where a start or resume begins; the newest listen wins.
- `WatchResumeCandidates.swift` — Builds those candidates from the full progress snapshot.
- `WatchPlaybackFailure.swift` — Audio-engine errors and their classification.
- `WatchNowPlayingProjection.swift` — What Now Playing shows and which controls are live, without an owner.
- `WatchPlaybackMachine.swift` — Pure playback reducer: phases, attempt tokens and the ordered effects each request or completion asks for; the Watch controller interprets it on a serial lane.
- `WatchPlaybackNotice.swift` — Why a start is refused (`WatchPlaybackReadiness`, typed `WatchBusyHolder`) and the listener-facing text of every playback notice.
- `WatchStallPolicy.swift` — When a wanted stream has stopped for good: the 15-second bound, an immediate stall on failing to play to the end, one report per episode.
- `WatchInterruptionPolicy.swift` — What interruptions and route changes do: pause what plays, resume only what an interruption paused.
- `WatchArtworkCache.swift` — Bounded disk cache of compressed thumbnails: on-demand tier (16 MB / 512) and phone-pushed synced tier (48 MB / 8,192), raw image files plus one index read at open.
- `WatchArtworkSyncPlan.swift` — Pure Watch-side cover-sync rules: stamp acceptance, aliasing, pruning and want-list batching.
- `WatchArtworkRevisions.swift` — Phone-reported cover revisions per account and cover.

Watch resources in `App/WhirrWatch Watch App/`:

- `WhirrWatch Watch App.entitlements` — Watch application entitlements.
- `Assets.xcassets/Contents.json` — asset catalogue metadata.
- `Assets.xcassets/AccentColor.colorset/Contents.json` — accent colour definition.
- `Assets.xcassets/AppIcon.appiconset/Contents.json` — icon asset registration.
- `Assets.xcassets/AppIcon.appiconset/AppIcon.png` — Watch application icon.

## Widget source map

The extension links `WidgetProtocol` and nothing else from the package, and compiles
`App/Whirr/Playback/SiriPlaybackIntents.swift` so it can name the shared intents; its performer
refuses them, because the system runs them in the app. It reads only the App Group files the app
writes (SECURITY.md rule 21).

### Shared values — `Packages/Core/Sources/WidgetProtocol/`

- `WidgetSnapshot.swift` — The snapshot, its items, now-playing state and stats window, validated on init.
- `WidgetSnapshotCodec.swift` — Bounded, sorted-key JSON, validated before encoding and after decoding.
- `WidgetStorageLayout.swift` — The App Group identifier and the `Widgets/` paths both sides resolve.
- `WidgetShelfPresentation.swift`, `WidgetControlPresentation.swift`, `WidgetStatsPresentation.swift` — What each surface draws, decided from the snapshot.
- `SleepTimerActivity.swift` — The Live Activity's attributes and content state; ActivityKit guarded to iOS.
- `WidgetTapDestination.swift` — The `whirr://widget/…` tap links the extension builds and the app parses strictly.
- `WidgetSmartLists.swift`, `WidgetSmartListPresentation.swift` — The smart list widget's file, codec and reader, and what it draws.

### Phone publishing — `App/Whirr/Widgets/`

- `WidgetRuntime.swift` — Process-lifetime owner; bind, unbind, token resolution for intents.
- `WidgetSnapshotPublisher.swift` — Observes the shelves, player and stored stats; writes on change.
- `WidgetSnapshotAssembly.swift`, `WidgetStatsAssembly.swift` — The pure publication: rows, tokens, cover requests, stats window.
- `WidgetSmartListAssembly.swift`, `WidgetSmartListFeed.swift` — The smart list file's pure publication and the feed that observes shown lists live and reads the rest on lifecycle events.
- `WidgetFileStore.swift`, `WidgetCoverExporter.swift`, `WidgetTokenMap.swift` — Files in the App Group and the app-private token map.
- `SleepTimerActivityDriver.swift`, `ActivityKitSleepTimerSink.swift` — The Live Activity, driven from the player behind a sink tests replace.
- `WidgetTapRouter.swift` — Resolves a tap link to navigation; `WidgetTapInbox` holds it until `RootView` has the library shell mounted.

### Extension — `App/WhirrWidgets/`

- `WhirrWidgetsBundle.swift` — Every widget, control and activity the extension offers.
- `WidgetSnapshotReader.swift`, `WidgetSharedViews.swift` — Reads the snapshot; the shared provider, rows and play button.
- `ContinueListeningWidget.swift`, `NewEpisodesWidget.swift`, `ListeningStatsWidget.swift`, `SmartListWidget.swift`, `ListeningAccessoryWidget.swift` — Home Screen and Lock Screen widgets; the smart list widget's configuration intent and entity live in `SiriPlaybackIntents.swift`.
- `PlayPauseControl.swift`, `SkipBackControl.swift`, `SleepTimerControl.swift` — Controls.
- `SleepTimerLiveActivity.swift` — Lock Screen and Dynamic Island views.

## Tests and fixtures

- Package tests mirror targets under `Packages/Core/Tests/<Target>Tests/`.
- Shared fakes and JSON fixtures live in `Packages/Core/Sources/TestSupport/`.
- iOS adapter, composition, and presentation tests live in `App/WhirrTests/`.
- Watch host programs live in `Scripts/watch-regressions/`, documented by their own README.
- Advisory performance scenarios live in `App/WhirrPerformanceTests/`.
- Design-system semantic snapshots live under
  `Packages/Core/Tests/DesignSystemTests/__Snapshots__/`.

Use `swift test --package-path Packages/Core` for the fast loop and `Scripts/check-format.sh` for
format verification. The full merge gate, App lanes included, is in
[docs/TESTING.md](docs/TESTING.md#merge-gate).

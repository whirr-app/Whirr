import ABSApi
import AppModel
import Foundation
import Persistence
import PodcastFeeds
import SyncEngine
import UIKit

extension AppEnvironment {
  struct PlaybackComposition {
    let outboxStore: OutboxStore
    /// The ordinary keyed drain every progress writer shares (one `OutboxDrainRequester`).
    let requestDrain: @Sendable () async -> Void
    let requestLocalSessionUploadDrain: @concurrent @Sendable () async -> Void
    let requestFinishedDownloadDeletion: @Sendable (String, String?) async -> Void
    let playbackSyncing: any PlaybackSyncing
    let itemProgressCoordinator: ItemProgressCoordinator
    let audioBookmarkCoordinator: AudioBookmarkCoordinator
    let rssEpisodeStore: RSSEpisodeStore
    /// What plays before Up Next while a smart list runs (ADR 0016).
    let continuation: any PlaybackContinuationSource
    /// The active run as the Up Next sheet and the Play Next copy read it.
    let smartListRun: SmartListRunModel
  }

  /// Non-secret device/app identification for every `/play` request's `deviceInfo`
  /// (API-CONVENTIONS.md rule 6). Excludes `UIDevice.current.name`, the user-chosen device name,
  /// even though it is a legal field:
  /// `manufacturer`/`model`/`clientVersion`/`clientName` already identify the client without it.
  private static var deviceMetadata: PlaybackDeviceMetadata {
    PlaybackDeviceMetadata(
      clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
      manufacturer: "Apple",
      model: UIDevice.current.model,
      clientName: "Whirr"
    )
  }

  @MainActor
  static func makePlaybackComposition(
    hardware: PlaybackHardware,
    database: AppDatabase,
    smartListServices: SmartListServices,
    accountDAO: AccountDAO,
    client: ABSClient,
    diagnostics: DiagnosticsStore,
    networkConditions: NetworkConditionsReducer,
    downloadStore: DownloadStore,
    downloadFileStore: DownloadFileStore,
    downloadCoordinator: DownloadCoordinator,
    downloadPreferences: any DownloadPreferences,
    rssFileStore: RSSFileStore,
    feedCredentialStore: any FeedCredentialStoring,
    podcastServices: PodcastBackgroundRefreshHardware.SharedServices,
    nativePodcastSubscriptions: NativePodcastSubscriptionsPreference,
    isSignedIn: Bool
  ) -> PlaybackComposition {
    // `OutboxStore.init` only fails if recovering stale `sending` rows itself fails, which cannot
    // happen against a database this file already proved is openable/writable moments ago
    // (`makeDatabase()`'s `fatalError` guard).
    let outboxStore = try! OutboxStore(database: database)

    // Ties the knot between `PlaybackSessionCoordinator` (needs `requestDrain` at construction)
    // and the `OutboxDrainer` that closure builds (needs a `notifySessionGoneRecovery` callback
    // into that same coordinator). See `PlaybackCoordinatorBox`.
    let coordinatorBox = PlaybackCoordinatorBox()
    // Both drain triggers below go through one requester, which owns the single `OutboxDrainer`
    // they share. Every serialisation guard that drainer documents is instance state, so a
    // drainer built per trigger would never fire one (see `OutboxDrainRequester`).
    let drainRequester = OutboxDrainRequester(
      accountDAO: accountDAO,
      outboxStore: outboxStore,
      database: database,
      absClient: client,
      diagnostics: diagnostics,
      notifySessionGoneRecovery: { itemID, episodeID in
        await coordinatorBox.coordinator?.recoverFromSessionGone(itemID: itemID, episodeID: episodeID)
      }
    )
    let requestDrain: @Sendable () async -> Void = { await drainRequester.drainOutbox() }

    // The bounded `local-all` batch drain rather than the keyed per-entity one. Same drainer,
    // different entry point.
    let requestLocalSessionUploadDrain: @concurrent @Sendable () async -> Void = {
      await drainRequester.drainLocalSessionUploads()
    }

    // Playback completion and an explicit "Mark as Finished" are the same user-visible state
    // transition, so both routes share one medium-aware download cleanup action.
    let requestFinishedDownloadDeletion: @Sendable (String, String?) async -> Void = {
      itemID, episodeID in
      if let episodeID {
        try? await downloadCoordinator.purgeEpisodeDownload(
          itemID: itemID, episodeID: episodeID, source: .finishedDownloadAutoDelete)
      } else {
        try? await downloadCoordinator.purgeItemDownload(
          itemID: itemID, source: .finishedDownloadAutoDelete)
      }
    }

    let playbackCoordinator = PlaybackSessionCoordinator.make(
      client: client,
      database: database,
      outbox: outboxStore,
      networkConditions: networkConditions,
      deviceMetadata: deviceMetadata,
      requestDrain: requestDrain,
      downloadStore: downloadStore,
      downloadFileStore: downloadFileStore,
      requestLocalSessionUploadDrain: requestLocalSessionUploadDrain,
      // Reaps only after playback completion, against the same shared reaper
      // `PodcastBackgroundRefreshHardware.handle()` uses.
      requestPodcastAutoDownloadReap: { await podcastServices.podcastAutoDownloadReaper?.reap() },
      downloadPreferences: downloadPreferences,
      requestFinishedDownloadDeletion: requestFinishedDownloadDeletion
    )
    coordinatorBox.coordinator = playbackCoordinator

    let itemProgressCoordinator = try! ItemProgressCoordinator(
      database: database,
      requestDrain: requestDrain,
      downloadPreferences: downloadPreferences,
      requestFinishedDownloadDeletion: requestFinishedDownloadDeletion)
    // Same outbox and drain as progress: each bookmark write lands with its outbox row, then asks
    // for a drain.
    let audioBookmarkCoordinator = AudioBookmarkCoordinator(
      database: database, requestDrain: requestDrain)

    // Native playback prepares one enclosure entirely from device-owned RSS rows. The media
    // framework stays at the App leaf; Core owns only the duration-loading seam and policy.
    // Natural completion of a device-owned episode is the same finish as an account-owned one, so
    // it takes the same preference and the same cleanup action as `PlaybackSessionCoordinator`.
    let rssEpisodeStore = RSSEpisodeStore(database: database)
    let rssPlaybackCoordinator = RSSPlaybackCoordinator(
      episodeStore: rssEpisodeStore,
      stateStore: RSSEpisodeStateStore(database: database),
      durationResolver: RSSEpisodeDurationResolver(
        episodeStore: rssEpisodeStore,
        downloadDurationStore: RSSDownloadDurationStore(database: database),
        loader: AVAssetEnclosureDurationLoader()),
      chapterResolver: RSSEpisodeChapterResolver(
        chapterStore: RSSEpisodeChapterStore(database: database),
        loader: AVAssetEmbeddedChapterLoader()),
      fileStore: rssFileStore,
      activePlaybackTracker: podcastServices.rssActivePlaybackTracker,
      feedStore: RSSFeedStore(database: database),
      credentialStore: feedCredentialStore,
      downloadPreferences: downloadPreferences,
      requestFinishedDownloadDeletion: requestFinishedDownloadDeletion,
      requestPodcastAutoDownloadReap: { await podcastServices.rssPodcastAutoDownloadReaper?.reap() },
      settleObserver: PodcastCloudSyncComposition.runtime)
    let routedPlaybackSyncing = RoutingPlaybackSyncing(
      abs: playbackCoordinator, rss: rssPlaybackCoordinator)

    // `AVQueuePlayerAudioEngine.configure(tracks:)` must run against `PreparedPlayback`'s resolved
    // stream URLs before the matching `.load`, and this decorator does that (see its doc
    // comment). `hardware.engine`/`hardware.player` are the process-lifetime singleton every
    // `AppEnvironment` rebuild shares, never rebuilt here.
    let playbackSyncing = StreamConfiguringPlaybackSyncing(
      underlying: routedPlaybackSyncing, engine: hardware.engine)
    // The same decorator is also what re-mints stream credentials when the engine reports a 401.
    // It owns both the account's `PlaybackSyncing` and the engine whose resources have to be
    // re-stamped.
    hardware.bindStreamAuthorizationRenewer(playbackSyncing)

    // The run's list reads through a factory because the reading bakes the native preference in:
    // a switch flipped mid-run must reach the next completion. A list has something to play while
    // native subscriptions are on or an account is signed in; otherwise completion plays Up Next.
    let smartListContinuation = SmartListContinuation(
      runs: SmartListRunStore(database: database),
      reading: {
        SmartListEpisodesReading(
          database: database, nativeEnabled: nativePodcastSubscriptions.isEnabledNow)
      },
      hasAvailableSource: { nativePodcastSubscriptions.isEnabledNow || isSignedIn })
    let smartListRun = SmartListRunModel(
      services: smartListServices, continuation: smartListContinuation)

    return PlaybackComposition(
      outboxStore: outboxStore,
      requestDrain: requestDrain,
      requestLocalSessionUploadDrain: requestLocalSessionUploadDrain,
      requestFinishedDownloadDeletion: requestFinishedDownloadDeletion,
      playbackSyncing: playbackSyncing,
      itemProgressCoordinator: itemProgressCoordinator,
      audioBookmarkCoordinator: audioBookmarkCoordinator,
      rssEpisodeStore: rssEpisodeStore,
      continuation: smartListContinuation,
      smartListRun: smartListRun)
  }
}

import AppModel
import Persistence
import PlayerCore
import SyncEngine

/// One `PlaybackModel` over the `FakePlaybackSyncing`/`FakePlaybackControlling` pair the playback
/// suites share, plus the start plumbing they repeat.
///
/// Every boundary the model takes is a parameter, and one a suite omits keeps the model's own
/// default. That matters for the suites that assert on the *absence* of a boundary: a harness that
/// pinned, say, a download-reading fake would silently stop those suites from testing `nil`.
///
/// The payload helpers are deliberately payload-first. A prepared playback carries the item and
/// episode IDs, tracks, chapters and source the test asserts on, so the harness never invents one.
@MainActor
public struct PlaybackModelHarness {
  public let model: PlaybackModel
  public let player: FakePlaybackControlling
  public let sync: FakePlaybackSyncing
  public let account: FakeAccountLifecycle
  public let appLifecycle: FakeAppLifecycle

  public init(
    sync: FakePlaybackSyncing = FakePlaybackSyncing(),
    player: FakePlaybackControlling = FakePlaybackControlling(),
    account: FakeAccountLifecycle = FakeAccountLifecycle(),
    appLifecycle: FakeAppLifecycle = FakeAppLifecycle(),
    bookmarkStore: (any PlaybackBookmarkStoring)? = nil,
    nativePodcastSubscriptions: (any NativePodcastSubscriptionsReading)? = nil,
    listeningQueue: (any ListeningQueueStoring)? = nil,
    rateCoordinator: PlaybackRateCoordinator? = nil,
    requestReachabilityProbe: (@Sendable () -> Void)? = nil,
    bufferingClock: (any PlaybackBufferingClock)? = nil,
    downloadReading: (any DownloadReading)? = nil,
    skipRanges: (any PlaybackSkipRangeSource)? = nil,
    timeSaved: (any TimeSavedRecording)? = nil,
    trim: PlaybackTrimDependencies? = nil,
    continuation: (any PlaybackContinuationSource)? = nil
  ) {
    self.sync = sync
    self.player = player
    self.account = account
    self.appLifecycle = appLifecycle
    model = PlaybackModel(
      sync: sync, player: player, account: account, appLifecycle: appLifecycle,
      bookmarkStore: bookmarkStore ?? NoOpPlaybackBookmarkStoring(),
      nativePodcastSubscriptions: nativePodcastSubscriptions
        ?? NoOpNativePodcastSubscriptionsReading(),
      listeningQueue: listeningQueue ?? NoOpListeningQueueStore(),
      rateCoordinator: rateCoordinator,
      requestReachabilityProbe: requestReachabilityProbe ?? {},
      bufferingClock: bufferingClock ?? SystemPlaybackBufferingClock(),
      downloadReading: downloadReading,
      skipRanges: skipRanges,
      timeSaved: timeSaved,
      trim: trim,
      continuation: continuation ?? NoOpPlaybackContinuationSource())
  }

  /// Stubs the next `startSession` result. The caller keeps ownership of the payload.
  public func stubPrepared(_ prepared: PreparedPlayback) {
    sync.stubStartSession(.success(prepared))
  }

  /// Stubs `prepared` and starts the identity it carries, which is what the streaming suites do
  /// before pushing progress.
  public func startStreaming(_ prepared: PreparedPlayback, fromStart: Bool = false) async {
    stubPrepared(prepared)
    await model.start(itemID: prepared.itemID, episodeID: prepared.episodeID, fromStart: fromStart)
  }
}

import ABSApi
import Foundation
import Persistence

/// Production `PlaybackSyncing` conformance: orchestrates `/play`/`/close` around the durable
/// `PlaybackSessionStore`. SyncEngine alone may call `/play`, `/sync` or `/close`
/// (ARCHITECTURE.md §2).
///
/// Session requests are serialised by device via an explicit task chain (`serialized(_:)`), since
/// actor reentrancy does not serialise across `await` points (ARCHITECTURE.md §3): two concurrent
/// top-level calls could both see "no active session" and give one device two locally-active
/// sessions. v1 has one signed-in account/device, so one chain per coordinator suffices, matching
/// `PlaybackSessionRecord`'s one-active-session-per-account unique index.
///
/// Cadence scheduling lives on the same actor: PlayerCore-phase and immediate-trigger entry points
/// drive a small state machine that asks an injected `requestDrain` closure to run. It never calls
/// `/sync`/`/close` itself, classifies responses or mutates deltas/acknowledgements.
/// `networkConditions.changes` gives this coordinator its own replaying subscription, created
/// after construction because a plain actor `init` cannot let `self` escape into a `Task` closure
/// (see `SyncEngine.make`).
public actor PlaybackSessionCoordinator: PlaybackSyncing {
  let client: ABSClient
  let accountDAO: AccountDAO
  let itemDAO: ItemDAO
  let itemChapterStore: ItemChapterStore
  let podcastEpisodeChapterStore: PodcastEpisodeChapterStore
  let podcastEpisodeDAO: PodcastEpisodeDAO
  let mediaProgressDAO: MediaProgressDAO
  let sessionStore: PlaybackSessionStore
  let clock: any SyncClock
  let deviceMetadata: PlaybackDeviceMetadata
  let generateClientSessionID: @Sendable () -> String
  let progressMerge = ProgressMergePolicy()
  /// `nil` in any composition that never wired downloads, in which case `resolveSource` always
  /// decides `.streaming`.
  let downloadStore: DownloadStore?
  let downloadFileStore: DownloadFileStore?

  /// The device-keyed serialisation chain (see the type doc comment above).
  private var tail: Task<Void, Never>?
  /// The last successfully prepared value per local session row id. Makes a repeated
  /// `startSession` call for the still-active item idempotent (no second `/play`).
  var preparedBySessionID: [Int64: PreparedPlayback] = [:]
  /// Set once by `quiesceForLogout` and never cleared. A fresh login builds a fresh coordinator.
  var isQuiescedForLogout = false
  /// Owns the live network-condition subscription for this coordinator's lifetime. The stream's
  /// producer may otherwise keep a suspended `for await` task alive after teardown, even when the
  /// task captures the coordinator weakly.
  var networkSubscriberTask: Task<Void, Never>?

  // MARK: - Progress-tick state

  /// Per-session outbox-coalescing segment counter for `recordProgressTick`. Bumped on a seek or a
  /// finished/un-finished transition, never on an ordinary tick. A fresh session id (a switch, a
  /// relaunch) has no entry, so its first tick always opens segment 0.
  var progressSegmentBySessionID: [Int64: Int] = [:]
  /// The `isFinished` value `recordProgressTick` last saw for a given session, used only to
  /// detect the transition that starts a fresh segment.
  var lastFinishedBySessionID: [Int64: Bool] = [:]
  /// The verified online target from the preceding accepted tick. The serialized coordinator
  /// invalidates this on any failed write, so ordinary half-second ticks avoid re-reading account,
  /// item, active-local-session, and active-online-session identity every time.
  var cachedOnlineTickTarget: OnlineTickTarget?
  /// The durable tick writes, always `sessionStore` in production. Substitutable so a test can make
  /// one branch's write throw, since no fixture can stage a real mid-listen SQLite failure.
  var tickWriter: any PlaybackTickWriting
  /// The tick trace's emit, substitutable like `emitCadenceRecord` because the production side is
  /// a DEBUG-only `NSLog` no test can observe.
  var emitTickRecord: @Sendable (PlaybackTickTrace.Record) -> Void = {
    PlaybackTickTrace.emit($0)
  }

  struct OnlineTickTarget {
    let accountRecord: AccountRecord
    let itemID: String
    let episodeID: String?
    let itemRowId: Int64
    var session: PlaybackSessionRecord
  }

  /// What this device is playing, independent of whether a session survives. Set by a successful
  /// `performStart`, cleared only by `performStop`, so it stays correct however a session dies
  /// under live audio. `persistTick` uses it to tell a tick worth rescuing from a straggler for a
  /// displaced item (tracked separately below).
  var activePlaybackItem: ActivePlaybackItem?
  /// The one item a switch most recently displaced. A final tick can arrive after the former
  /// session closed but before PlayerCore stops emitting the outgoing item's identity.
  var displacedPlaybackItem: ActivePlaybackItem?

  /// What `performStop` retired, and when. A stop normally ends the listening, so the tick or two
  /// emitted as it lands are stragglers and stay dropped. But a stop while audio carries on
  /// disarms `activePlaybackItem` and `displacedPlaybackItem` and so every `persistTick` branch,
  /// losing listening time with no signal outside DEBUG. Ticks arriving well past any straggler
  /// window show the audio never stopped, so the net re-arms.
  var retiredPlaybackItem: RetiredPlaybackItem?

  /// The first tick observed by a coordinator that has never successfully started anything.
  /// PlayerCore/AVPlayer are process-lifetime while this coordinator is account-scoped, so a
  /// replacement can be born under live audio. One event looks like a stale delivery; sustained
  /// ticks for the same identity do not, as with a retired item above.
  var unarmedPlaybackCandidate: RetiredPlaybackItem?

  /// Two `progressPersistInterval`s. A straggler is emitted as the stop lands, not a minute later.
  static let stragglerGrace: TimeInterval = 30

  struct ActivePlaybackItem: Equatable {
    let itemID: String
    let episodeID: String?
    let itemRowId: Int64
    let episodeRowId: Int64?
    let accountId: Int64
  }

  struct RetiredPlaybackItem {
    let item: ActivePlaybackItem
    let stoppedAt: Date
  }

  // MARK: - Progress-tick throttle

  /// Ordinary half-second ticks accumulate here instead of each committing a SQLite transaction.
  /// One durable write lands per `progressPersistInterval`, plus an immediate one at every
  /// boundary outside code can observe (seek/finished/item change, any drain request, and
  /// stop/switch before the close path reads `globalPosition`). Every mutation and flush is
  /// synchronous on the actor, with no suspension between deciding and writing, so a flush never
  /// interleaves with a tick queued on the serialised chain.
  ///
  /// Injectable so an integration harness on a real on-disk database can restore per-tick
  /// durability (`0` persists every tick).
  var progressThrottle: ProgressPersistThrottle
  let resetCheckTimeout: TimeInterval

  // MARK: - Cadence state

  let scheduler: any PlaybackCadenceScheduling
  let requestDrain: @Sendable () async -> Void
  /// Requests a `local-all` reconciliation drain when an offline session closes on a switch to a
  /// streaming item. With no reachability boundary, a streaming resolution stands in for "now
  /// non-offline". Defaults to a no-op; the drainer's in-flight flag coalesces it with other
  /// triggers.
  let requestLocalSessionUploadDrain: @Sendable () async -> Void
  /// Reaps downloads after playback completion only. Fires from the coordinator's own durable
  /// "the episode just finished" signal (`performRecordProgressTick`'s not-finished to finished
  /// transition), so it runs once per genuine completion and never as a download pass. Defaults to
  /// a no-op.
  let requestPodcastAutoDownloadReap: @Sendable () async -> Void
  let downloadPreferences: any DownloadPreferences
  let requestFinishedDownloadDeletion: @Sendable (String, String?) async -> Void
  var cadencePhase: PlaybackCadencePhase = .idle
  /// Bumped by every `notifyPlaybackPhase` call. `reopenSessionIfResumedWithoutOne` restores the
  /// `.playing` phase its `performStart` reset only if no newer notification arrived while it was
  /// suspended on the serialised chain: a later player-reported phase must win.
  var phaseNotificationEpoch = 0
  /// Cadence measurement (`DrainCadenceTrace`). Bookkeeping only: emits nothing outside DEBUG and
  /// influences no scheduling decision.
  var cadenceRecorder = DrainCadenceRecorder()
  /// The trace's only production effect is a DEBUG-only `NSLog` no test can observe, so the emit
  /// goes through a sink that only tests replace.
  var emitCadenceRecord: @Sendable (DrainCadenceTrace.Record) -> Void = {
    DrainCadenceTrace.emit($0)
  }
  var networkSnapshot: NetworkConditionsSnapshot
  /// Coalescing guard: a trigger arriving while a drain request is running only sets
  /// `drainRequestedAgain`, so co-incident triggers collapse into one extra call once the
  /// in-flight one finishes.
  var drainInFlight = false
  var drainRequestedAgain = false
  /// Close/switch callers cannot proceed while their close row is merely coalesced behind a drain
  /// already in flight: the old active row still owns the schema's one-session slot. Ordinary
  /// cadence callers fire and coalesce; only finalisation waits on these.
  var drainCompletionWaiters: [CheckedContinuation<Void, Never>] = []

  static let normalCadenceInterval: TimeInterval = 15
  static let degradedCadenceInterval: TimeInterval = 60
  /// How long ordinary ticks accumulate in memory before one durable write. Matches the normal
  /// drain cadence, so a periodic `/sync` never reads a position older than one interval.
  public static let progressPersistInterval: TimeInterval = 15
  /// How long a guarded start waits on its reset check before starting from the local position.
  /// The check only ever adds evidence, so giving up costs a conflict row, never a position.
  public static let resetCheckTimeout: TimeInterval = 3

  public init(
    client: ABSClient,
    database: AppDatabase,
    outbox: OutboxStore,
    deviceMetadata: PlaybackDeviceMetadata = PlaybackDeviceMetadata(),
    clock: any SyncClock = SystemSyncClock(),
    clientSessionIDGenerator: @escaping @Sendable () -> String = { UUID().uuidString },
    scheduler: any PlaybackCadenceScheduling = SystemPlaybackCadenceScheduler(),
    initialNetworkConditions: NetworkConditionsSnapshot = NetworkConditionsSnapshot(
      isLowPowerMode: false, isConstrainedOrCellular: false),
    requestDrain: @escaping @Sendable () async -> Void = {},
    downloadStore: DownloadStore? = nil,
    downloadFileStore: DownloadFileStore? = nil,
    requestLocalSessionUploadDrain: @escaping @Sendable () async -> Void = {},
    requestPodcastAutoDownloadReap: @escaping @Sendable () async -> Void = {},
    downloadPreferences: any DownloadPreferences = NoOpDownloadPreferences(),
    requestFinishedDownloadDeletion: @escaping @Sendable (String, String?) async -> Void = { _, _ in },
    progressPersistInterval: TimeInterval = PlaybackSessionCoordinator.progressPersistInterval,
    resetCheckTimeout: TimeInterval = PlaybackSessionCoordinator.resetCheckTimeout
  ) {
    self.client = client
    accountDAO = AccountDAO(database: database)
    itemDAO = ItemDAO(database: database)
    itemChapterStore = ItemChapterStore(database: database)
    podcastEpisodeChapterStore = PodcastEpisodeChapterStore(database: database)
    podcastEpisodeDAO = PodcastEpisodeDAO(database: database)
    mediaProgressDAO = MediaProgressDAO(database: database)
    let store = PlaybackSessionStore(database: database, outbox: outbox)
    sessionStore = store
    tickWriter = store
    self.deviceMetadata = deviceMetadata
    self.clock = clock
    generateClientSessionID = clientSessionIDGenerator
    self.scheduler = scheduler
    networkSnapshot = initialNetworkConditions
    self.requestDrain = requestDrain
    self.downloadStore = downloadStore
    self.downloadFileStore = downloadFileStore
    self.requestLocalSessionUploadDrain = requestLocalSessionUploadDrain
    self.requestPodcastAutoDownloadReap = requestPodcastAutoDownloadReap
    self.downloadPreferences = downloadPreferences
    self.requestFinishedDownloadDeletion = requestFinishedDownloadDeletion
    progressThrottle = ProgressPersistThrottle(interval: progressPersistInterval)
    self.resetCheckTimeout = resetCheckTimeout
  }

  /// Constructs a coordinator whose cadence also reacts to live `NetworkConditions` changes. The
  /// public construction path that needs the changes stream, shaped like `SyncEngine.make` for the
  /// same actor-initialiser reason: `self` cannot safely escape into a subscriber `Task` from a
  /// plain `init`, so the subscription is wired here against a fully-constructed instance. The
  /// subscriber handle is stored by the coordinator and cancelled by `quiesceForLogout`.
  public static func make(
    client: ABSClient,
    database: AppDatabase,
    outbox: OutboxStore,
    networkConditions: any NetworkConditions,
    deviceMetadata: PlaybackDeviceMetadata = PlaybackDeviceMetadata(),
    clock: any SyncClock = SystemSyncClock(),
    clientSessionIDGenerator: @escaping @Sendable () -> String = { UUID().uuidString },
    scheduler: any PlaybackCadenceScheduling = SystemPlaybackCadenceScheduler(),
    requestDrain: @escaping @Sendable () async -> Void = {},
    downloadStore: DownloadStore? = nil,
    downloadFileStore: DownloadFileStore? = nil,
    requestLocalSessionUploadDrain: @escaping @Sendable () async -> Void = {},
    requestPodcastAutoDownloadReap: @escaping @Sendable () async -> Void = {},
    downloadPreferences: any DownloadPreferences = NoOpDownloadPreferences(),
    requestFinishedDownloadDeletion: @escaping @Sendable (String, String?) async -> Void = { _, _ in }
  ) -> PlaybackSessionCoordinator {
    let coordinator = PlaybackSessionCoordinator(
      client: client, database: database, outbox: outbox, deviceMetadata: deviceMetadata, clock: clock,
      clientSessionIDGenerator: clientSessionIDGenerator, scheduler: scheduler,
      initialNetworkConditions: NetworkConditionsSnapshot(
        isLowPowerMode: networkConditions.isLowPowerMode,
        isConstrainedOrCellular: networkConditions.isConstrainedOrCellular),
      requestDrain: requestDrain, downloadStore: downloadStore, downloadFileStore: downloadFileStore,
      requestLocalSessionUploadDrain: requestLocalSessionUploadDrain,
      requestPodcastAutoDownloadReap: requestPodcastAutoDownloadReap,
      downloadPreferences: downloadPreferences,
      requestFinishedDownloadDeletion: requestFinishedDownloadDeletion)
    let stream = networkConditions.changes
    let task = Task { [weak coordinator] in
      for await snapshot in stream {
        guard Task.isCancelled == false, let coordinator else { return }
        await coordinator.handleNetworkConditionsChange(snapshot)
      }
    }
    Task { [weak coordinator] in
      await coordinator?.storeNetworkSubscriberTask(task)
    }
    return coordinator
  }

  private func storeNetworkSubscriberTask(_ task: Task<Void, Never>) {
    guard isQuiescedForLogout == false else {
      task.cancel()
      return
    }
    networkSubscriberTask = task
  }

  // MARK: - Explicit device-keyed serialization

  /// Chains `operation` onto whatever is already queued so concurrent calls apply in one order,
  /// however long any `await` inside `operation` takes. Reassigning `tail` is synchronous (no
  /// `await` between reading the previous tail and storing the new one), so this critical section
  /// cannot interleave even under actor reentrancy. Only the awaited `operation` bodies run one
  /// at a time.
  func serialized<T: Sendable>(_ operation: @Sendable @escaping () async throws -> T) async throws -> T {
    let previous = tail
    let task = Task<T, Error> {
      _ = await previous?.value
      return try await operation()
    }
    tail = Task {
      _ = try? await task.value
    }
    return try await task.value
  }
}

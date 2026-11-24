import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

extension PlaybackModelTests {
  // MARK: - Fixtures

  static func makeModel() -> (
    model: PlaybackModel, player: FakePlaybackControlling, sync: FakePlaybackSyncing,
    account: FakeAccountLifecycle, appLifecycle: FakeAppLifecycle
  ) {
    makeModelWithProbe()
  }

  static func makeStartedModel(
    requestReachabilityProbe: @escaping @Sendable () -> Void = {},
    bufferingClock: any PlaybackBufferingClock = FakePlaybackBufferingClock()
  ) async -> (
    model: PlaybackModel, player: FakePlaybackControlling, sync: FakePlaybackSyncing,
    account: FakeAccountLifecycle, appLifecycle: FakeAppLifecycle
  ) {
    let result = Self.makeModel(
      requestReachabilityProbe, bufferingClock: bufferingClock)
    result.sync.stubStartSession(.success(Self.preparedPlayback(startPosition: 0)))
    await result.model.start(itemID: "item-1")
    return result
  }

  static func makeModel(
    _ requestReachabilityProbe: @escaping @Sendable () -> Void,
    bufferingClock: any PlaybackBufferingClock = FakePlaybackBufferingClock()
  ) -> (
    model: PlaybackModel, player: FakePlaybackControlling, sync: FakePlaybackSyncing,
    account: FakeAccountLifecycle, appLifecycle: FakeAppLifecycle
  ) {
    let (model, player, sync, account, appLifecycle) = makeModelWithProbe(
      requestReachabilityProbe: requestReachabilityProbe, bufferingClock: bufferingClock)
    return (model, player, sync, account, appLifecycle)
  }

  static func makeModelWithProbe(
    requestReachabilityProbe: @escaping @Sendable () -> Void = {},
    bufferingClock: any PlaybackBufferingClock = FakePlaybackBufferingClock()
  ) -> (
    model: PlaybackModel, player: FakePlaybackControlling, sync: FakePlaybackSyncing,
    account: FakeAccountLifecycle, appLifecycle: FakeAppLifecycle
  ) {
    let (model, player, sync, _, account, appLifecycle) = makeModelWithBookmarkStore(
      requestReachabilityProbe: requestReachabilityProbe, bufferingClock: bufferingClock)
    return (model, player, sync, account, appLifecycle)
  }

  static func makeModelWithBookmarkStore() -> (
    model: PlaybackModel, player: FakePlaybackControlling, sync: FakePlaybackSyncing,
    bookmarkStore: FakePlaybackBookmarkStoring, account: FakeAccountLifecycle, appLifecycle: FakeAppLifecycle
  ) {
    makeModelWithBookmarkStore(requestReachabilityProbe: {})
  }

  static func makeModelWithBookmarkStore(
    requestReachabilityProbe: @escaping @Sendable () -> Void,
    bufferingClock: any PlaybackBufferingClock = FakePlaybackBufferingClock()
  ) -> (
    model: PlaybackModel, player: FakePlaybackControlling, sync: FakePlaybackSyncing,
    bookmarkStore: FakePlaybackBookmarkStoring, account: FakeAccountLifecycle, appLifecycle: FakeAppLifecycle
  ) {
    let player = FakePlaybackControlling()
    let sync = FakePlaybackSyncing()
    let bookmarkStore = FakePlaybackBookmarkStoring()
    let account = FakeAccountLifecycle()
    let appLifecycle = FakeAppLifecycle()
    let model = PlaybackModel(
      sync: sync, player: player, account: account, appLifecycle: appLifecycle, bookmarkStore: bookmarkStore,
      requestReachabilityProbe: requestReachabilityProbe, bufferingClock: bufferingClock)
    return (model, player, sync, bookmarkStore, account, appLifecycle)
  }

  static func makeReachabilityMonitor() -> ServerReachabilityMonitor {
    // Backgrounded, so the monitor's startup lifecycle task cannot race a test's `.didNotReach`:
    // handled foreground-and-unreachable, it starts a recovery probe, and this no-op probe
    // "succeeds" and flips the state back to `.reachable` before the test observes the outage.
    let lifecycle = FakeAppLifecycle()
    lifecycle.isForeground = false
    return ServerReachabilityMonitor(
      path: PlaybackModelStaticPathObserving(),
      probe: PlaybackModelNoOpServerStatusProbe(),
      appLifecycle: lifecycle,
      clock: FakeSyncClock(),
      scheduler: FakePlaybackCadenceScheduling(),
      timeoutScheduler: FakePlaybackCadenceScheduling())
  }

  static func makeRateModel(
    globalRate: Double = 1.25
  ) -> (
    model: PlaybackModel, player: FakePlaybackControlling, sync: FakePlaybackSyncing,
    rateCoordinator: PlaybackRateCoordinator
  ) {
    let player = FakePlaybackControlling()
    let sync = FakePlaybackSyncing()
    let store = FakeItemPlaybackSettingsAccess()
    let preferences = FakePlaybackPreferences(initialRate: globalRate)
    let rateCoordinator = PlaybackRateCoordinator(
      reading: store, writing: store, preferences: preferences, player: player)
    let model = PlaybackModel(
      sync: sync, player: player, account: FakeAccountLifecycle(),
      appLifecycle: FakeAppLifecycle(), rateCoordinator: rateCoordinator)
    return (model, player, sync, rateCoordinator)
  }

  static func bookmark(
    itemID: String, episodeID: String? = nil, isFinished: Bool = false,
    positionSeconds: Double = 10
  ) -> PlaybackBookmark {
    PlaybackBookmark(
      serverItemId: itemID, episodeID: episodeID, title: "Title \(itemID)",
      author: "Author", durationSeconds: 100, positionSeconds: positionSeconds,
      isFinished: isFinished)
  }

  /// Suspends until the model's observable display state satisfies `predicate`.
  static func waitForDisplayState(
    _ model: PlaybackModel, satisfying predicate: (PlaybackModel) -> Bool
  ) async {
    await waitUntil { predicate(model) }
  }

  static func preparedPlayback(
    itemID: String = "item-1", episodeID: String? = nil, startPosition: Double,
    chapters: [PreparedPlaybackChapter] = [
      PreparedPlaybackChapter(id: 1, start: 0, end: 100, title: "Ch1")
    ],
    source: PreparedPlaybackSource = .streaming
  ) -> PreparedPlayback {
    PlaybackFixture.prepared(
      itemID: itemID,
      episodeID: episodeID,
      startPosition: startPosition,
      duration: 100,
      tracks: [
        PlaybackFixture.track(
          index: 0, startOffset: 0, duration: 100, url: URL(string: "https://example.test/track.mp3")!,
          mimeType: "audio/mpeg", title: "Track 1")
      ],
      chapters: chapters,
      source: source
    )
  }

  static func loadedItems(from intents: [PlayerIntent]) -> [PlayerItem] {
    intents.compactMap { intent in
      if case .load(let item, _, _, _) = intent { return item }
      return nil
    }
  }

  static func loadRates(_ intents: [PlayerIntent]) -> [Double] {
    intents.compactMap { intent in
      if case .load(_, _, let rate, _) = intent { return rate }
      return nil
    }
  }

  static func setRateCalls(_ intents: [PlayerIntent]) -> [Double] {
    intents.compactMap { intent in
      if case .setRate(let rate) = intent { return rate }
      return nil
    }
  }

  // Nonisolated so the `@Sendable` predicates handed to `waitForCalls` (evaluated off the main
  // actor, under the fake's own lock) can use them too.

  nonisolated static func tickCalls(_ calls: [FakePlaybackSyncing.RecordedCall]) -> [(
    itemID: String, currentTime: Double, listenedDelta: Double, isFinished: Bool, isSeek: Bool
  )] {
    calls.compactMap {
      if case .recordProgressTick(let itemID, let currentTime, let listenedDelta, let isFinished, let isSeek) = $0 {
        return (itemID, currentTime, listenedDelta, isFinished, isSeek)
      }
      return nil
    }
  }

  nonisolated static func cadencePhaseCalls(
    _ calls: [FakePlaybackSyncing.RecordedCall]
  ) -> [PlaybackCadencePhase] {
    calls.compactMap {
      if case .notifyPlaybackPhase(let phase) = $0 { return phase }
      return nil
    }
  }

  nonisolated static func seekCompletedTriggerCount(_ calls: [FakePlaybackSyncing.RecordedCall]) -> Int {
    calls.filter { $0 == .notifyImmediateSyncTrigger(.seekCompleted) }.count
  }
}

// MARK: - Fakes

final class ChangeCounter: @unchecked Sendable {
  private(set) var count = 0

  func mark() { count += 1 }
}

final class ReachabilityProbeCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func fire() {
    lock.lock()
    value += 1
    lock.unlock()
  }
}

final class FakePlaybackBufferingClock: PlaybackBufferingClock, @unchecked Sendable {
  // Always held: a sleep parks until `advance`/`resumePending`, and returns at once if its task is
  // cancelled.
  private let gate = TestGate<Void>(label: "FakePlaybackBufferingClock sleep")

  init() {
    gate.hold()
  }

  func sleep() async {
    await gate.pass()
  }

  var pendingSleepCount: Int {
    gate.parkedCount
  }

  func advance() async {
    await gate.waitUntilParked()
    resumePending()
  }

  func resumePending() {
    gate.releaseParked()
  }
}

struct PlaybackModelStaticPathObserving: PathObserving {
  let currentPath = PathSnapshot(isSatisfied: true, isCellular: false, isConstrained: false)

  func startObserving(onUpdate: @escaping @Sendable (PathSnapshot) -> Void) {}
  func stopObserving() {}
}

struct PlaybackModelNoOpServerStatusProbe: ServerStatusProbing {
  func probeServerStatus() async throws {}
}

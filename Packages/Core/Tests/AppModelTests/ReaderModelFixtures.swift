import Foundation
import Persistence
import PlayerCore
import ReaderCore
import SyncEngine
import Synchronization
import TestSupport
import Testing

@testable import AppModel

extension ReaderModelTests {
  // MARK: - Fixtures

  /// Ten pages, one-based, with chapter 2 opening on page 4, opened and reading at `page`.
  func openScrubbableBook(at page: Int) async -> (ReaderModel, FakeEPUBRendering) {
    let positions = (1...10).map {
      position(total: Double($0) / 10, href: "position-\($0)", position: $0)
    }
    let publication = OpenedEPUBPublication(
      toc: [
        TOCEntry(title: "Chapter 1", href: "Text/chapter-1.xhtml#c1", position: 1, depth: 0),
        TOCEntry(title: "Chapter 2", href: "Text/chapter-2.xhtml#c2", position: 4, depth: 0),
      ],
      positions: positions,
      reflowable: true)
    let stateReading = TestReaderStateReading()
    let renderer = FakeEPUBRendering(publication: publication)
    let model = makeModel(stateReading: stateReading, renderer: renderer)
    await open(model, stateReading: stateReading)
    let current = positions[page - 1]
    renderer.emit(current)
    await waitUntil { model.currentPosition == current }
    return (model, renderer)
  }

  func makeModel(
    itemID: String = "book-1",
    category: ItemMediaCategory = .ebook,
    stateReading: TestReaderStateReading = TestReaderStateReading(),
    progress: TestReaderProgressAccess = TestReaderProgressAccess(),
    preferences: TestReaderPreferencesStore = TestReaderPreferencesStore(),
    extrasAccess: FakeItemDetailExtrasAccess = FakeItemDetailExtrasAccess(),
    downloads: FakeDownloadIntents = FakeDownloadIntents(),
    renderer: FakeEPUBRendering = FakeEPUBRendering(),
    lifecycle: any AppLifecycle = FakeAppLifecycle(),
    playbackInterlock: any ReaderPlaybackInterlock = NoOpReaderPlaybackInterlock(),
    restoreBudget: Duration = .seconds(5),
    openingIndicatorThreshold: Duration = .seconds(5)
  ) -> ReaderModel {
    ReaderModel(
      itemID: itemID,
      category: category,
      stateReading: stateReading,
      progress: progress,
      extrasAccess: extrasAccess,
      preferencesStore: preferences,
      downloadIntents: downloads,
      renderer: renderer,
      appLifecycle: lifecycle,
      playbackInterlock: playbackInterlock,
      restoreBudget: restoreBudget,
      openingIndicatorThreshold: openingIndicatorThreshold)
  }

  static func makePlaybackHarness() -> PlaybackHarness {
    let player = FakePlaybackControlling()
    let sync = FakePlaybackSyncing()
    let queue = RecordingListeningQueue()
    let playback = PlaybackModel(
      sync: sync, player: player, account: FakeAccountLifecycle(),
      appLifecycle: FakeAppLifecycle(), listeningQueue: queue)
    return PlaybackHarness(playback: playback, player: player, sync: sync, queue: queue)
  }

  static func prepared(itemID: String, episodeID: String? = nil) -> PreparedPlayback {
    PreparedPlayback(
      itemID: itemID, episodeID: episodeID, startPosition: 0, duration: 100,
      tracks: [
        PreparedPlaybackTrack(
          index: 0, startOffset: 0, duration: 100,
          url: URL(string: "https://example.test/audio.mp3")!, mimeType: "audio/mpeg",
          title: itemID)
      ], chapters: [])
  }

  static func queueRow(_ id: Int64, _ identity: ListeningIdentity) -> ListeningQueueItem {
    ListeningQueueItem(
      id: id, position: Int(id) - 1, identity: identity, primaryTitle: "Row \(id)",
      secondaryTitle: "Secondary",
      category: identity.episodeID == nil ? .audiobook : .podcast, isTombstone: false,
      chapter: nil)
  }

  struct PlaybackHarness {
    let playback: PlaybackModel
    let player: FakePlaybackControlling
    let sync: FakePlaybackSyncing
    let queue: RecordingListeningQueue

    @MainActor
    func start(itemID: String, episodeID: String?) async {
      sync.stubStartSession(.success(ReaderModelTests.prepared(itemID: itemID, episodeID: episodeID)))
      await playback.start(itemID: itemID, episodeID: episodeID)
    }
  }

  static let emptyExtras = ItemDetailExtras(seriesName: nil, narrator: nil, chapters: [])

  func open(
    _ model: ReaderModel,
    stateReading: TestReaderStateReading,
    state: ReaderState = .downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub"))
  ) async {
    let task = Task { await model.open() }
    await stateReading.waitUntilSubscribed()
    stateReading.push(state)
    await task.value
  }

  func position(total: Double, href: String, position: Int? = nil) -> ReadingPosition {
    ReadingPosition(
      href: href, progression: total, totalProgression: total, position: position)
  }
}

// MARK: - Fakes

enum TestReaderError: Error, Sendable {
  case download
  case write
  case preferences
  case restore
}

final class TestReaderStateReading: ReaderStateReading, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: AsyncStream<ReaderState>.Continuation?
  private var pendingState: ReaderState?
  private var subscriptions = 0

  func observeReaderState(itemId: String) -> AsyncStream<ReaderState> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      self.install(continuation)
    }
  }

  func push(_ state: ReaderState) {
    lock.lock()
    defer { lock.unlock() }
    if let continuation {
      continuation.yield(state)
    } else {
      pendingState = state
    }
  }

  /// `count` is which subscription to wait for. A reader that retries subscribes a second time,
  /// and waiting on "has ever subscribed" would return on the first one's leftovers.
  func finish() {
    lock.lock()
    defer { lock.unlock() }
    continuation?.finish()
    continuation = nil
  }

  func waitUntilSubscribed(count: Int = 1) async {
    await waitUntil { self.subscriptionCount >= count }
  }

  private func install(_ continuation: AsyncStream<ReaderState>.Continuation) {
    lock.lock()
    defer { lock.unlock() }
    self.continuation = continuation
    subscriptions += 1
    if let pendingState {
      continuation.yield(pendingState)
      self.pendingState = nil
    }
  }

  private var subscriptionCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return subscriptions
  }
}

actor TestReaderProgressAccess: ReaderProgressAccessing {
  var restoreTarget: ReaderRestoreTarget?
  var writtenPositions: [ReadingPosition] = []
  var writeAttemptCount = 0
  private var writeFailuresRemaining: Int
  var finishedItemIDs: [String] = []
  var events: [String] = []
  var syncRequestCount = 0
  private(set) var syncWasCancelled = false
  // A gated call stays parked through task cancellation until released, like a read that runs
  // to completion regardless.
  private nonisolated let syncGate = TestGate<Void>(
    label: "TestReaderProgressAccess requestSync", ignoresCancellation: true)
  let audioCurrentTime = 137.0
  private nonisolated let fetchGate = TestGate<Result<ReaderRestoreTarget?, TestReaderError>>(
    label: "TestReaderProgressAccess fetchRestoreTarget", ignoresCancellation: true)
  private(set) var fetchWasRequested = false

  init(
    restoreTarget: ReaderRestoreTarget? = nil,
    writeFailuresRemaining: Int = 0,
    gateFetch: Bool = false,
    fetchError: TestReaderError? = nil,
    gateSync: Bool = false
  ) {
    self.restoreTarget = restoreTarget
    self.writeFailuresRemaining = writeFailuresRemaining
    self.fetchError = fetchError
    if gateFetch { fetchGate.hold() }
    if gateSync { syncGate.hold() }
  }

  private let fetchError: TestReaderError?

  func fetchRestoreTarget(itemID: String) async throws -> ReaderRestoreTarget? {
    fetchWasRequested = true
    if fetchGate.isHeld {
      return try await fetchGate.pass(otherwise: { [result = fetchResult] in result }).get()
    }
    if let fetchError { throw fetchError }
    return restoreTarget
  }

  private var fetchResult: Result<ReaderRestoreTarget?, TestReaderError> {
    fetchError.map { .failure($0) } ?? .success(restoreTarget)
  }

  func releaseFetch() async {
    // The gated read records its request just before it parks.
    if fetchWasRequested && fetchGate.isHeld { await fetchGate.waitUntilParked() }
    fetchGate.release(fetchResult)
  }

  func write(position: ReadingPosition, itemID: String) async throws {
    writeAttemptCount += 1
    if writeFailuresRemaining > 0 {
      writeFailuresRemaining -= 1
      throw TestReaderError.write
    }
    writtenPositions.append(position)
    events.append("write")
  }

  func markEbookAsFinished(itemID: String) async throws {
    finishedItemIDs.append(itemID)
  }

  func requestSync() async {
    syncRequestCount += 1
    events.append("sync")
    if syncGate.isHeld { await syncGate.pass() }
    syncWasCancelled = Task.isCancelled
  }

  func releaseSync() async {
    // The gated sync counts its request just before it parks.
    if syncRequestCount > 0 && syncGate.isHeld { await syncGate.waitUntilParked() }
    syncGate.release()
  }
}

actor TestReaderPreferencesStore: ReaderPreferencesStoring {
  var valueJSON: String?
  var writes: [ReaderPreferences] = []
  private nonisolated let fetchGate = TestGate<Result<String?, TestReaderError>>(
    label: "TestReaderPreferencesStore fetchPreferencesJSON", ignoresCancellation: true)
  private let fetchError: TestReaderError?
  private(set) var fetchWasRequested = false

  init(
    value: ReaderPreferences? = nil,
    gateFetch: Bool = false,
    fetchError: TestReaderError? = nil
  ) {
    self.fetchError = fetchError
    valueJSON = value.flatMap { try? String(decoding: JSONEncoder().encode($0), as: UTF8.self) }
    if gateFetch { fetchGate.hold() }
  }

  func fetchPreferencesJSON() async throws -> String? {
    fetchWasRequested = true
    if fetchGate.isHeld {
      return try await fetchGate.pass(otherwise: { [result = fetchResult] in result }).get()
    }
    if let fetchError { throw fetchError }
    return valueJSON
  }

  private var fetchResult: Result<String?, TestReaderError> {
    fetchError.map { .failure($0) } ?? .success(valueJSON)
  }

  func releaseFetch() async {
    // The gated read records its request just before it parks.
    if fetchWasRequested && fetchGate.isHeld { await fetchGate.waitUntilParked() }
    fetchGate.release(fetchResult)
  }

  func writePreferencesJSON(_ preferencesJSON: String) async throws {
    valueJSON = preferencesJSON
    if let preferences = try? JSONDecoder().decode(
      ReaderPreferences.self, from: Data(preferencesJSON.utf8))
    {
      writes.append(preferences)
    }
  }
}

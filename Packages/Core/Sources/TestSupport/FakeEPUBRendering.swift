import Foundation
import ReaderCore
import Testing

/// A Foundation-only, in-memory renderer used by ReaderCore and future AppModel tests.
/// It records the frozen protocol calls and exposes `emit(_:)` for deterministic position-feed
/// tests; it has no Readium or UIKit dependency.
@MainActor
public final class FakeEPUBRendering: EPUBRendering {
  public private(set) var lifecycleState: EPUBRenderingLifecycleState = .stopped
  public private(set) var openedLocalFileURLs: [URL] = []
  public private(set) var openRequests: [EPUBOpenRequest] = []
  public private(set) var goToPositions: [ReadingPosition] = []
  public private(set) var goToTotalProgressions: [Double] = []
  public private(set) var goToSearchHitIDs: [String] = []
  public private(set) var turnPageDirections: [ReaderPageDirection] = []
  public private(set) var submittedPreferences: [ReaderPreferences] = []
  public private(set) var searchedQueries: [String] = []
  public private(set) var cancelSearchCallCount = 0
  public private(set) var closeCallCount = 0
  public private(set) var highlightedSearchHitID: String?

  /// Makes both `go` overloads never return, so a test can pin that a restore cannot hold the
  /// opened book hostage.
  public var hangsOnRestore = false
  /// Consumed one entry per navigation call. A `true` entry throws; a `false` entry returns.
  /// When the script is empty, navigation succeeds unless `alwaysFailNavigation` is set.
  public var navigationFailureScript: [Bool] = []
  public var alwaysFailNavigation = false
  /// Test-only gate for making `open(_:)` remain suspended after recording its request.
  /// Parks every `open` until `releaseOpen()` while set.
  public var waitsForOpenRelease: Bool {
    get { openGate.isHeld }
    set { newValue ? openGate.hold() : openGate.release() }
  }
  public let openGate = TestGate<Void>(label: "FakeEPUBRendering.open", ignoresCancellation: true)

  public var nextOpenFailure: EPUBRenderingOpenFailure?
  public var startFailure: EPUBRenderingOpenFailure?
  public var turnPageResult = true
  public var isSearchable = false
  public var searchHits: [ReaderSearchHit] = []
  /// When non-empty, search yields the configured pages one at a time. The first page is yielded
  /// immediately; call `releaseNextSearchHitBatch()` to release each following page.
  public var searchHitBatches: [[ReaderSearchHit]] = []
  public var nextSearchFailure: ReaderSearchFailure?

  public private(set) var positionUpdates: AsyncStream<ReadingPosition>

  private let publication: OpenedEPUBPublication
  private var positionContinuation: AsyncStream<ReadingPosition>.Continuation
  private var searchContinuation: AsyncThrowingStream<[ReaderSearchHit], any Error>.Continuation?
  private var currentSearchHitBatches: [[ReaderSearchHit]] = []
  private var currentSearchBatchIndex = 0
  private var currentSearchHitIDs = Set<String>()

  public init(publication: OpenedEPUBPublication = OpenedEPUBPublication()) {
    self.publication = publication
    var continuation: AsyncStream<ReadingPosition>.Continuation!
    positionUpdates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
      continuation = $0
    }
    positionContinuation = continuation
  }

  public func start() async throws {
    if let startFailure {
      throw startFailure
    }
    guard lifecycleState == .stopped else { return }
    lifecycleState = .ready
  }

  public func open(_ request: EPUBOpenRequest) async throws -> OpenedEPUBPublication {
    guard lifecycleState != .stopped else {
      throw EPUBRenderingOpenFailure.serverFailure
    }
    if let nextOpenFailure {
      self.nextOpenFailure = nil
      throw nextOpenFailure
    }

    openRequests.append(request)
    await openGate.pass()

    if lifecycleState == .publicationOpen {
      cancelSearchState()
      positionContinuation.finish()
    }
    makePositionFeed()
    openedLocalFileURLs.append(request.localFileURL)
    lifecycleState = .publicationOpen
    return publication
  }

  public func close() async {
    closeCallCount += 1
    guard lifecycleState == .publicationOpen else { return }
    cancelSearchState()
    positionContinuation.finish()
    lifecycleState = .ready
  }

  public func stop() async {
    cancelSearchState()
    if lifecycleState == .publicationOpen {
      positionContinuation.finish()
    }
    lifecycleState = .stopped
  }

  /// Test-only: waits, bounded, for a gated open to park, then lets it continue. Waiting first
  /// means a release cannot land between the open being recorded and it parking.
  public func releaseOpen() async {
    await openGate.waitUntilParked()
    openGate.releaseParked()
  }

  public func go(to position: ReadingPosition) async throws {
    goToPositions.append(position)
    try failNavigationIfScripted()
    try await Self.hangIfNeeded(hangsOnRestore)
  }

  public func go(toTotalProgression progression: Double) async throws {
    goToTotalProgressions.append(progression)
    try failNavigationIfScripted()
    try await Self.hangIfNeeded(hangsOnRestore)
  }

  public func search(query: String) -> AsyncThrowingStream<[ReaderSearchHit], any Error> {
    cancelSearchState()
    searchedQueries.append(query)
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedQuery.isEmpty == false else {
      return AsyncThrowingStream { continuation in continuation.finish() }
    }
    guard lifecycleState == .publicationOpen, isSearchable else {
      return AsyncThrowingStream { continuation in
        continuation.finish(throwing: ReaderSearchFailure.notSearchable)
      }
    }

    if let nextSearchFailure {
      self.nextSearchFailure = nil
      return AsyncThrowingStream { continuation in
        continuation.finish(throwing: nextSearchFailure)
      }
    }

    let batches = searchHitBatches.isEmpty ? (searchHits.isEmpty ? [] : [searchHits]) : searchHitBatches
    currentSearchHitBatches = batches
    currentSearchBatchIndex = 0
    return AsyncThrowingStream { continuation in
      self.searchContinuation = continuation
      guard let first = batches.first else {
        continuation.finish()
        self.searchContinuation = nil
        return
      }
      self.currentSearchHitIDs.formUnion(first.map(\.id))
      continuation.yield(first)
      if batches.count == 1 {
        continuation.finish()
        self.searchContinuation = nil
      }
    }
  }

  public func cancelSearch() async {
    cancelSearchCallCount += 1
    cancelSearchState()
  }

  /// Test-only: releases the next configured search page without introducing a timing dependency.
  public func releaseNextSearchHitBatch() {
    guard let searchContinuation else { return }
    let nextIndex = currentSearchBatchIndex + 1
    guard currentSearchHitBatches.indices.contains(nextIndex) else {
      searchContinuation.finish()
      self.searchContinuation = nil
      return
    }

    currentSearchBatchIndex = nextIndex
    let batch = currentSearchHitBatches[nextIndex]
    currentSearchHitIDs.formUnion(batch.map(\.id))
    searchContinuation.yield(batch)
    if nextIndex == currentSearchHitBatches.index(before: currentSearchHitBatches.endIndex) {
      searchContinuation.finish()
      self.searchContinuation = nil
    }
  }

  public func highlightSearchHit(id: String?) async {
    highlightedSearchHitID = id
  }

  public func go(toSearchHit id: String) async throws {
    guard currentSearchHitIDs.contains(id) else {
      throw ReaderSearchFailure.reading
    }
    goToSearchHitIDs.append(id)
  }

  /// The shape of a Readium navigator whose web view never reports the navigation as finished: the
  /// call records the request and then simply never comes back.
  private static func hangIfNeeded(_ shouldHang: Bool) async throws {
    guard shouldHang else { return }
    try await Task.sleep(for: .seconds(3_600))
  }

  public func turnPage(_ direction: ReaderPageDirection) async -> Bool {
    turnPageDirections.append(direction)
    return turnPageResult
  }

  public func submit(preferences: ReaderPreferences) async throws {
    submittedPreferences.append(preferences)
  }

  private func failNavigationIfScripted() throws {
    let shouldFail =
      navigationFailureScript.isEmpty
      ? alwaysFailNavigation
      : navigationFailureScript.removeFirst()
    if shouldFail {
      throw FakeEPUBRenderingNavigationFailure.scripted
    }
  }

  /// Test-only: simulates the renderer emitting a position update.
  public func emit(_ position: ReadingPosition) {
    positionContinuation.yield(position)
  }

  private func makePositionFeed() {
    var continuation: AsyncStream<ReadingPosition>.Continuation!
    positionUpdates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
      continuation = $0
    }
    positionContinuation = continuation
  }

  private func cancelSearchState() {
    searchContinuation?.finish()
    searchContinuation = nil
    currentSearchHitBatches.removeAll()
    currentSearchBatchIndex = 0
    currentSearchHitIDs.removeAll()
    highlightedSearchHitID = nil
  }
}

public enum FakeEPUBRenderingNavigationFailure: Error, Equatable, Sendable {
  case scripted
}

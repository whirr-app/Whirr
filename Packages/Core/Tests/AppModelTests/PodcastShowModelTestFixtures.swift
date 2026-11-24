import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

enum PodcastFixtureError: Error { case offline }

/// Bridges `PodcastShowModelTests+Selection.swift`, which still builds its reading under this name
/// and calls `push`.
typealias PodcastShowFixtureReading = FakePodcastReading

extension FakePodcastReading {
  func push(_ episodes: [PodcastEpisodeSummary], itemID: String) {
    pushEpisodes(episodes, itemID: itemID)
  }
}

// Kept: one ordered log of the stop-playback closure and `unsubscribe`, with a held stop, to
// prove the stop happens first. `FakeNativeFeedManaging` has no stop-playback member to log.
actor UnfollowSequence: NativeFeedManaging {
  enum Call: Sendable, Equatable {
    case stop(String)
    case unsubscribe(Int64)
  }

  private let recorder = CallRecorder<Call>(label: "UnfollowSequence")
  private let stopError: (any Error)?
  // A held stop stays parked through task cancellation until `releaseStop()`.
  private nonisolated let stopGate = TestGate<Void>(
    label: "UnfollowSequence stopPlayback", ignoresCancellation: true)

  var calls: [Call] { recorder.calls }

  init(stopError: (any Error)? = nil, holdsStop: Bool = false) {
    self.stopError = stopError
    if holdsStop { stopGate.hold() }
  }

  func stopPlayback(itemID: String) async throws {
    recorder.record(.stop(itemID))
    await stopGate.pass()
    if let stopError { throw stopError }
  }

  /// Waits until a stop has been called and, when the stop is held, until it is parked.
  func waitUntilStopCalled() async {
    await recorder.waitUntil { calls in
      calls.contains { call in
        if case .stop = call { return true }
        return false
      }
    }
    if stopGate.isHeld { await stopGate.waitUntilParked() }
  }

  func releaseStop() {
    stopGate.release()
  }

  func unsubscribe(feedId: Int64) async throws { recorder.record(.unsubscribe(feedId)) }
  func hasCredential(feedId: Int64) async throws -> Bool { false }
  func saveBasicCredential(username: String, password: String, feedId: Int64) async throws {}
  func clearCredential(feedId: Int64) async throws {}
}

// Kept: `PodcastShowModelTests+Selection.swift` (outside this packet) awaits its actor members
// (`calls`, `reset`, `failNext`, `fail(episodeIDs:)`), which `FakePodcastEpisodeIntents` has not.
actor PodcastShowFixtureEpisodeIntents: PodcastEpisodeIntents {
  enum Call: Equatable {
    case play(String, String)
    case playNext(String, String)
    case addToUpNext(String, String)
    case saveForLater(String, String)
    case removeFromSaved(String, String)
    case download(String, String)
    case pauseDownload(String, String)
    case resumeDownload(String, String)
    case removeDownload(String, String)
    case markAsFinished(String, String, Double?)
    case resetProgress(String, String)
    case markAll(String, [EpisodeProgressChange], Bool)
  }
  private(set) var calls: [Call] = []
  private var saveOutcome: SavedShelfSaveOutcome = .saved
  private var shouldFail = false
  private var failingEpisodeIDs: Set<String> = []
  private var failure: (any Error)?
  func failNext() { shouldFail = true }
  /// Fails every call for these episodes until cleared; other episodes succeed.
  func fail(episodeIDs: Set<String>) { failingEpisodeIDs = episodeIDs }
  func setSaveOutcome(_ outcome: SavedShelfSaveOutcome) { saveOutcome = outcome }
  func failNext(with error: any Error) {
    shouldFail = true
    failure = error
  }
  func play(itemID: String, episodeID: String) async throws {
    try checkFailure(episodeID: episodeID)
    calls.append(.play(itemID, episodeID))
  }
  func playNext(itemID: String, episodeID: String) async throws {
    try checkFailure(episodeID: episodeID)
    calls.append(.playNext(itemID, episodeID))
  }
  func addToUpNext(itemID: String, episodeID: String) async throws {
    try checkFailure(episodeID: episodeID)
    calls.append(.addToUpNext(itemID, episodeID))
  }
  @discardableResult
  func saveForLater(itemID: String, episodeID: String) async throws -> SavedShelfSaveOutcome {
    try checkFailure(episodeID: episodeID)
    calls.append(.saveForLater(itemID, episodeID))
    return saveOutcome
  }
  func removeFromSaved(itemID: String, episodeID: String) async throws {
    try checkFailure(episodeID: episodeID)
    calls.append(.removeFromSaved(itemID, episodeID))
  }
  func download(itemID: String, episodeID: String) async throws {
    try checkFailure(episodeID: episodeID)
    calls.append(.download(itemID, episodeID))
  }
  func pauseDownload(itemID: String, episodeID: String) async throws {
    try checkFailure(episodeID: episodeID)
    calls.append(.pauseDownload(itemID, episodeID))
  }
  func resumeDownload(itemID: String, episodeID: String) async throws {
    try checkFailure(episodeID: episodeID)
    calls.append(.resumeDownload(itemID, episodeID))
  }
  func removeDownload(itemID: String, episodeID: String) async throws {
    try checkFailure(episodeID: episodeID)
    calls.append(.removeDownload(itemID, episodeID))
  }
  func markAsFinished(itemID: String, episodeID: String, duration: Double?) async throws {
    try checkFailure(episodeID: episodeID)
    calls.append(.markAsFinished(itemID, episodeID, duration))
  }
  func resetProgress(itemID: String, episodeID: String) async throws {
    try checkFailure(episodeID: episodeID)
    calls.append(.resetProgress(itemID, episodeID))
  }
  func markAll(
    itemID: String, episodes: [EpisodeProgressChange], isFinished: Bool
  ) async throws {
    try checkFailure()
    calls.append(.markAll(itemID, episodes, isFinished))
  }
  func reset() { calls.removeAll() }

  private func checkFailure(episodeID: String? = nil) throws {
    if let episodeID, failingEpisodeIDs.contains(episodeID) { throw PodcastFixtureError.offline }
    if shouldFail {
      shouldFail = false
      let error = failure ?? PodcastFixtureError.offline
      failure = nil
      throw error
    }
  }
}

struct StaticShowRecoveryReading: NativeFeedRecoveryReading {
  let feedIDs: Set<Int64>

  func observeRecoveryFeedIDs() -> AsyncStream<Set<Int64>> {
    AsyncStream { continuation in
      continuation.yield(feedIDs)
      continuation.finish()
    }
  }

  func recoveryRequired(feedID: Int64) async throws -> Bool { feedIDs.contains(feedID) }
}

import Foundation
import PlayerCore
import SyncEngine
import Synchronization
import TestSupport
import Testing

@testable import AppModel

/// The loaded episode's ad-analysis status for the expanded player: asked on a local load,
/// asked again when the source signals, dropped for a stream, and Check Now goes to the
/// loaded file.
@Suite(.timeLimit(.minutes(1)))
struct PlaybackAdAnalysisStatusTests {
  typealias Ranges = PlaybackSkipRangeTests

  final class StatusSource: PlaybackSkipRangeSource {
    let statuses = Mutex<[URL: PlaybackAdAnalysisStatus]>([:])
    let checked = Mutex<[PlaybackSkipRangeRequest]>([])
    let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
      var continuation: AsyncStream<Void>.Continuation!
      changes = AsyncStream { continuation = $0 }
      self.continuation = continuation
    }

    func skipRanges(for request: PlaybackSkipRangeRequest) async -> [PlayerSkipRange] { [] }
    func skipRangeChanges() -> AsyncStream<Void> { AsyncStream { _ in } }
    func undoSkip(_ range: PlayerSkipRange, for request: PlaybackSkipRangeRequest) async {}

    func analysisStatus(for request: PlaybackSkipRangeRequest) async -> PlaybackAdAnalysisStatus {
      statuses.withLock { $0[request.fileURL] ?? .none }
    }

    func analysisStatusChanges() -> AsyncStream<Void> { changes }

    func checkNow(for request: PlaybackSkipRangeRequest) async {
      checked.withLock { $0.append(request) }
    }

    func set(_ status: PlaybackAdAnalysisStatus, for url: URL = Ranges.file) {
      statuses.withLock { $0[url] = status }
      continuation.yield()
    }
  }

  @MainActor
  static func makeModel(source: StatusSource) -> (PlaybackModel, FakePlaybackSyncing) {
    let playback = PlaybackModelHarness(skipRanges: source)
    return (playback.model, playback.sync)
  }

  @MainActor
  @Test("a local load shows the episode's status")
  func localLoadAsks() async throws {
    let source = StatusSource()
    source.set(.waiting(.conditions))
    let (model, sync) = Self.makeModel(source: source)
    sync.stubStartSession(.success(Ranges.prepared(source: .local)))

    await model.start(itemID: "show", episodeID: "episode-a")
    #expect(await waitUntil { model.adAnalysisStatus == .waiting(.conditions) })
  }

  @MainActor
  @Test("a signal from the source updates the status, through to ready")
  func signalUpdates() async throws {
    let source = StatusSource()
    source.set(.checking)
    let (model, sync) = Self.makeModel(source: source)
    sync.stubStartSession(.success(Ranges.prepared(source: .local)))
    await model.start(itemID: "show", episodeID: "episode-a")
    #expect(await waitUntil { model.adAnalysisStatus == .checking })

    source.set(.none)
    #expect(await waitUntil { model.adAnalysisStatus == .none })
  }

  @MainActor
  @Test("a stream has nothing to say, even after a local episode said something")
  func streamClears() async throws {
    let source = StatusSource()
    source.set(.checking)
    let (model, sync) = Self.makeModel(source: source)
    sync.stubStartSession(.success(Ranges.prepared(source: .local)))
    await model.start(itemID: "show", episodeID: "episode-a")
    #expect(await waitUntil { model.adAnalysisStatus == .checking })

    sync.stubStartSession(.success(Ranges.prepared(source: .streaming, episodeID: "episode-b")))
    await model.start(itemID: "show", episodeID: "episode-b")
    #expect(await waitUntil { model.adAnalysisStatus == .none })
    // A late signal must not bring the previous episode's status back.
    source.set(.checking)
    #expect(await waitUntil { model.adAnalysisStatus == .none })
  }

  @MainActor
  @Test("Check Now goes to the loaded file")
  func checkNowForwards() async throws {
    let source = StatusSource()
    let (model, sync) = Self.makeModel(source: source)
    sync.stubStartSession(.success(Ranges.prepared(source: .local)))
    await model.start(itemID: "show", episodeID: "episode-a")

    model.checkLoadedEpisodeForAds()
    #expect(
      await waitUntil {
        source.checked.withLock { $0 }
          == [PlaybackSkipRangeRequest(itemID: "show", episodeID: "episode-a", fileURL: Ranges.file)]
      })
  }

  @MainActor
  @Test("Check Now with nothing local loaded does nothing")
  func checkNowWithoutLoad() async throws {
    let source = StatusSource()
    let (model, _) = Self.makeModel(source: source)
    model.checkLoadedEpisodeForAds()
    #expect(source.checked.withLock { $0 }.isEmpty)
  }
}

import Foundation
import PlayerCore
import SyncEngine
import Synchronization
import TestSupport
import Testing

@testable import AppModel

/// Feeding detected ad ranges to the player: only for an analysed local file, again whenever
/// the stored ranges change, and the receipt with its Undo.
@Suite(.timeLimit(.minutes(1)))
struct PlaybackSkipRangeTests {
  static let ad = PlayerSkipRange(start: 30, end: 50, endsItem: false)
  static let file = URL(fileURLWithPath: "/downloads/show/episode-a.mp3")

  final class FakeSource: PlaybackSkipRangeSource {
    let ranges = Mutex<[URL: [PlayerSkipRange]]>([:])
    let requests = Mutex<[PlaybackSkipRangeRequest]>([])
    let undone = Mutex<[(PlaybackSkipRangeRequest, PlayerSkipRange)]>([])
    let changes: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
      var continuation: AsyncStream<Void>.Continuation!
      changes = AsyncStream { continuation = $0 }
      self.continuation = continuation
    }

    func skipRanges(for request: PlaybackSkipRangeRequest) async -> [PlayerSkipRange] {
      requests.withLock { $0.append(request) }
      return ranges.withLock { $0[request.fileURL] ?? [] }
    }

    func skipRangeChanges() -> AsyncStream<Void> { changes }

    func undoSkip(_ range: PlayerSkipRange, for request: PlaybackSkipRangeRequest) async {
      undone.withLock { $0.append((request, range)) }
    }

    func signalChange() { continuation.yield() }
  }

  /// Holds every request until the test answers it, oldest first.
  final class GatedSource: PlaybackSkipRangeSource {
    // A request runs to completion regardless of cancellation, so a cancelled one stays parked.
    let gate = TestGate<[PlayerSkipRange]>(
      label: "GatedSource skip ranges", ignoresCancellation: true)

    init() {
      gate.hold()
    }

    func skipRanges(for request: PlaybackSkipRangeRequest) async -> [PlayerSkipRange] {
      await gate.pass(otherwise: { [] })
    }

    func skipRangeChanges() -> AsyncStream<Void> { AsyncStream { _ in } }

    func undoSkip(_ range: PlayerSkipRange, for request: PlaybackSkipRangeRequest) async {}

    func answerOldest(_ ranges: [PlayerSkipRange]) {
      gate.releaseNext(ranges)
    }
  }

  @MainActor
  @Test("an answer for a file no longer loaded is dropped")
  func staleAnswerIsDropped() async throws {
    let source = GatedSource()
    let playback = PlaybackModelHarness(skipRanges: source)
    let model = playback.model
    let player = playback.player
    let sync = playback.sync
    sync.stubStartSession(.success(Self.prepared(source: .local)))
    await model.start(itemID: "show", episodeID: "episode-a")
    #expect(await source.gate.waitUntilParked(count: 1) == .observed)

    let other = URL(fileURLWithPath: "/downloads/show/episode-b.mp3")
    sync.stubStartSession(.success(Self.prepared(source: .local, episodeID: "episode-b", file: other)))
    await model.start(itemID: "show", episodeID: "episode-b")
    try #require(await source.gate.waitUntilParked(count: 2) == .observed)

    source.answerOldest([Self.ad])
    source.answerOldest([])
    let episodeB = PlayerIntent.setSkipRanges(itemID: "show", episodeID: "episode-b", ranges: [])
    #expect(await waitUntil { player.intents.contains(episodeB) })
    #expect(player.intents.contains(Self.setRanges([Self.ad])) == false)
  }

  @MainActor
  @Test("a local episode's ranges reach the player after its load")
  func localEpisodeRangesAreSent() async throws {
    let source = FakeSource()
    source.ranges.withLock { $0[Self.file] = [Self.ad] }
    let (model, player, sync) = Self.makeModel(source: source)
    sync.stubStartSession(.success(Self.prepared(source: .local)))

    await model.start(itemID: "show", episodeID: "episode-a")
    #expect(await waitUntil { player.intents.contains(Self.setRanges([Self.ad])) })

    let loadIndex = try #require(player.intents.firstIndex { if case .load = $0 { true } else { false } })
    let rangesIndex = try #require(player.intents.firstIndex(of: Self.setRanges([Self.ad])))
    #expect(loadIndex < rangesIndex)
    #expect(
      source.requests.withLock { $0 }
        == [PlaybackSkipRangeRequest(itemID: "show", episodeID: "episode-a", fileURL: Self.file)])
  }

  @MainActor
  @Test("a streamed episode never asks for ranges")
  func streamedEpisodeIsNotAsked() async throws {
    let source = FakeSource()
    let (model, player, sync) = Self.makeModel(source: source)
    sync.stubStartSession(.success(Self.prepared(source: .streaming)))

    // A streamed preparation returns before any request task exists, so no wait is needed.
    await model.start(itemID: "show", episodeID: "episode-a")

    #expect(source.requests.withLock { $0 }.isEmpty)
    #expect(player.intents.contains { if case .setSkipRanges = $0 { true } else { false } } == false)
  }

  @MainActor
  @Test("changed ranges are sent again for the loaded episode")
  func changedRangesAreResent() async throws {
    let source = FakeSource()
    let (model, player, sync) = Self.makeModel(source: source)
    sync.stubStartSession(.success(Self.prepared(source: .local)))
    await model.start(itemID: "show", episodeID: "episode-a")
    #expect(await waitUntil { player.intents.contains(Self.setRanges([])) })

    source.ranges.withLock { $0[Self.file] = [Self.ad] }
    source.signalChange()

    #expect(await waitUntil { player.intents.contains(Self.setRanges([Self.ad])) })
  }

  @MainActor
  @Test("a skip is published as a receipt, and Undo returns to the range and forgets the ad")
  func receiptAndUndo() async throws {
    let source = FakeSource()
    source.ranges.withLock { $0[Self.file] = [Self.ad] }
    let (model, player, sync) = Self.makeModel(source: source)
    sync.stubStartSession(.success(Self.prepared(source: .local)))
    await model.start(itemID: "show", episodeID: "episode-a")

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 9, itemId: "show", episodeID: "episode-a", phase: .seeking, currentTime: 50,
        listenedDelta: 0, skippedRange: Self.ad))
    #expect(await waitUntil { model.lastSkip != nil })
    #expect(model.lastSkip?.range == Self.ad)
    #expect(model.lastSkip?.canUndo == true)

    model.undoLastSkip()

    #expect(player.intents.last == .undoSkip(Self.ad))
    #expect(model.lastSkip == nil)
    #expect(await waitUntil { source.undone.withLock { $0.count } == 1 })
    #expect(source.undone.withLock { $0.first?.1 } == Self.ad)
  }

  @MainActor
  @Test("a range that ended the item has no Undo")
  func itemEndingSkipHasNoUndo() async throws {
    let source = FakeSource()
    let tail = PlayerSkipRange(start: 90, end: 100, endsItem: true)
    let (model, player, sync) = Self.makeModel(source: source)
    sync.stubStartSession(.success(Self.prepared(source: .local)))
    await model.start(itemID: "show", episodeID: "episode-a")

    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 9, itemId: "show", episodeID: "episode-a", phase: .ended, currentTime: 100,
        listenedDelta: 0, skippedRange: tail))
    #expect(await waitUntil { model.lastSkip != nil })
    #expect(model.lastSkip?.canUndo == false)

    model.undoLastSkip()

    #expect(player.intents.contains(.undoSkip(tail)) == false)
  }

  @MainActor
  @Test("the next load clears a receipt that outlived its item")
  func nextLoadClearsTheReceipt() async throws {
    let source = FakeSource()
    let tail = PlayerSkipRange(start: 90, end: 100, endsItem: true)
    let (model, player, sync) = Self.makeModel(source: source)
    sync.stubStartSession(.success(Self.prepared(source: .local)))
    await model.start(itemID: "show", episodeID: "episode-a")
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 9, itemId: "show", episodeID: "episode-a", phase: .ended, currentTime: 100,
        listenedDelta: 0, skippedRange: tail))
    #expect(await waitUntil { model.lastSkip != nil })

    await model.start(itemID: "show", episodeID: "episode-a")

    #expect(model.lastSkip == nil)
  }

  // MARK: - Helpers

  static func setRanges(_ ranges: [PlayerSkipRange]) -> PlayerIntent {
    .setSkipRanges(itemID: "show", episodeID: "episode-a", ranges: ranges)
  }

  @MainActor
  static func makeModel(source: FakeSource) -> (PlaybackModel, FakePlaybackControlling, FakePlaybackSyncing) {
    let playback = PlaybackModelHarness(skipRanges: source)
    return (playback.model, playback.player, playback.sync)
  }

  static func prepared(
    source: PreparedPlaybackSource, episodeID: String = "episode-a", file: URL = file
  ) -> PreparedPlayback {
    PlaybackFixture.prepared(
      itemID: "show", episodeID: episodeID, startPosition: 0, duration: 100,
      tracks: [
        PlaybackFixture.track(
          index: 0, startOffset: 0, duration: 100,
          url: source == .local ? file : URL(string: "https://example.test/episode.mp3")!,
          mimeType: "audio/mpeg", title: "episode-a")
      ],
      chapters: [], source: source)
  }
}

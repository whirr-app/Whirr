import Foundation
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// Undoing a range the transcript view shows, for the loaded episode.
extension PlaybackSkipRangeTests {

  @MainActor
  @Test("a view undo of the range just skipped returns to it and clears the receipt")
  func viewUndoOfTheReceiptsRange() async throws {
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

    model.undoSkippedRange(
      TranscriptAdRange(start: 30, end: 50, origin: .detected), itemID: "show",
      episodeID: "episode-a")

    #expect(player.intents.last == .undoSkip(Self.ad))
    #expect(model.lastSkip == nil)
    // The coordinator's half is the caller's: the model does not queue a second undo.
    #expect(source.undone.withLock { $0.isEmpty })
  }

  @MainActor
  @Test("a view undo of a range not skipped this load leaves the player alone")
  func viewUndoOfAnUnskippedRange() async throws {
    let source = FakeSource()
    source.ranges.withLock { $0[Self.file] = [Self.ad] }
    let (model, player, sync) = Self.makeModel(source: source)
    sync.stubStartSession(.success(Self.prepared(source: .local)))
    await model.start(itemID: "show", episodeID: "episode-a")

    model.undoSkippedRange(
      TranscriptAdRange(start: 30, end: 50, origin: .detected), itemID: "show",
      episodeID: "episode-a")

    #expect(player.intents.contains(.undoSkip(Self.ad)) == false)
  }

  @MainActor
  @Test("a view undo for another episode is ignored")
  func viewUndoForAnotherEpisode() async throws {
    let source = FakeSource()
    let (model, player, sync) = Self.makeModel(source: source)
    sync.stubStartSession(.success(Self.prepared(source: .local)))
    await model.start(itemID: "show", episodeID: "episode-a")
    player.pushProgress(
      PlaybackProgressEvent(
        sequence: 9, itemId: "show", episodeID: "episode-a", phase: .seeking, currentTime: 50,
        listenedDelta: 0, skippedRange: Self.ad))
    #expect(await waitUntil { model.lastSkip != nil })

    model.undoSkippedRange(
      TranscriptAdRange(start: 30, end: 50, origin: .detected), itemID: "show",
      episodeID: "episode-b")

    #expect(model.lastSkip != nil)
    #expect(player.intents.contains(.undoSkip(Self.ad)) == false)
  }
}

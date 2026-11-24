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
  // MARK: - Finish offers

  @Test("the finish offer is inert without a handler and reads one installed after construction")
  func finishOffererLateBindingIsInertAndReadsTheInstalledHandler() async {
    let offerer = ReaderFinishOfferer()
    await offerer.offerFinish()

    let offers = Mutex(0)
    offerer.handler = { offers.withLock { $0 += 1 } }
    #expect(offerer.handler != nil)
    await offerer.offerFinish()
    await offerer.offerFinish()
    #expect(offers.withLock { $0 } == 2)
  }

  @Test("the finish offer's handler slot is safe to install and read from several tasks")
  func finishOffererLateBindingIsThreadSafe() async {
    let offerer = ReaderFinishOfferer()
    let offers = Mutex(0)
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<50 {
        group.addTask {
          offerer.handler = { offers.withLock { $0 += 1 } }
        }
        group.addTask {
          await offerer.offerFinish()
        }
      }
    }
    offerer.handler = { offers.withLock { $0 += 1 } }
    await offerer.offerFinish()
    #expect(offers.withLock { $0 } >= 1)
  }

  @Test("ebook finish is offered and uses the ebook-safe path without changing audio time")
  func ebookFinishOfferAndSafeFinish() async {
    let stateReading = TestReaderStateReading()
    let progress = TestReaderProgressAccess()
    let renderer = FakeEPUBRendering()
    let model = makeModel(
      category: .ebook, stateReading: stateReading, progress: progress, renderer: renderer)
    await open(model, stateReading: stateReading)

    renderer.emit(position(total: 1, href: "end"))
    await waitUntil { model.isFinishOfferVisible }
    #expect(model.isFinishOfferVisible)
    await model.markFinished()

    #expect(await progress.finishedItemIDs == ["book-1"])
    #expect(progress.audioCurrentTime == 137.0)
  }

  @Test("bundled EPUB audiobooks do not expose a reader finish offer")
  func bundledAudiobookHasNoReaderFinishOffer() async {
    let stateReading = TestReaderStateReading()
    let progress = TestReaderProgressAccess()
    let renderer = FakeEPUBRendering()
    let model = makeModel(
      category: .audiobook, stateReading: stateReading, progress: progress, renderer: renderer)
    await open(model, stateReading: stateReading)

    renderer.emit(position(total: 1, href: "end"))
    await waitUntil { model.currentPosition?.href == "end" }
    #expect(model.isFinishOfferVisible == false)
    #expect(await progress.finishedItemIDs.isEmpty)
  }

  /// D7: the ebook finish writes the same item-wide flag the audio bookmark joins, so a live
  /// session for the book's audio has to stop first and the continuation wait for the write.
  @Test("finishing the ebook stops the book's playing audio and prepares the next row paused")
  func markFinishedStopsActiveAudioAndPreparesTheNextRow() async throws {
    let harness = Self.makePlaybackHarness()
    await harness.start(itemID: "book-1", episodeID: nil)
    let next = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    await harness.queue.configure(rows: [Self.queueRow(1, next)])
    harness.sync.stubStartSession(.success(Self.prepared(itemID: "book-2")))
    let baseline = harness.player.intents

    let stateReading = TestReaderStateReading()
    let progress = TestReaderProgressAccess()
    let renderer = FakeEPUBRendering()
    let model = makeModel(
      stateReading: stateReading, progress: progress, renderer: renderer,
      playbackInterlock: PlaybackReaderInterlock(playback: harness.playback))
    await open(model, stateReading: stateReading)
    renderer.emit(position(total: 1, href: "end"))
    await waitUntil { model.isFinishOfferVisible }

    await model.markFinished()

    #expect(harness.player.intents.contains(.stop))
    #expect(await progress.finishedItemIDs == ["book-1"])
    #expect(model.isFinishOfferVisible == false)
    let sent = Array(harness.player.intents.dropFirst(baseline.count))
    #expect(sent.contains(.play) == false, "finishing the book must not resume audio")
    #expect(sent.contains { if case .load = $0 { true } else { false } })
    #expect(harness.playback.loadedItemID == "book-2")
    #expect(harness.playback.startFailure == nil)
    #expect(
      await harness.queue.removed == [try #require(ListeningIdentity.audiobook(itemID: "book-1"))])
    #expect(await harness.queue.identities.isEmpty)
  }

  @Test("finishing the ebook leaves another book's audio untouched")
  func markFinishedLeavesInactiveAudioAlone() async throws {
    let harness = Self.makePlaybackHarness()
    await harness.start(itemID: "book-3", episodeID: nil)
    let baseline = harness.player.intents
    let queued = try #require(ListeningIdentity.audiobook(itemID: "book-2"))
    await harness.queue.configure(rows: [Self.queueRow(1, queued)])

    let stateReading = TestReaderStateReading()
    let progress = TestReaderProgressAccess()
    let renderer = FakeEPUBRendering()
    let model = makeModel(
      stateReading: stateReading, progress: progress, renderer: renderer,
      playbackInterlock: PlaybackReaderInterlock(playback: harness.playback))
    await open(model, stateReading: stateReading)
    renderer.emit(position(total: 1, href: "end"))
    await waitUntil { model.isFinishOfferVisible }

    await model.markFinished()

    #expect(harness.player.intents == baseline)
    #expect(await progress.finishedItemIDs == ["book-1"])
    #expect(await harness.queue.peekCount == 0)
    #expect(await harness.queue.removed.isEmpty)
    #expect(await harness.queue.identities == [queued])
    #expect(harness.playback.activeItemID == "book-3")
  }
}

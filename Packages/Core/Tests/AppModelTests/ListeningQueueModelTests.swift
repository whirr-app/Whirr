import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

@Suite(.timeLimit(.minutes(1))) struct ListeningQueueModelTests {
  @MainActor
  @Test("starts loading then renders the mixed database order and empty state")
  func loadingMixedOrderAndEmpty() async throws {
    let reading = FakeListeningQueueReading()
    let model = ListeningQueueModel(reading: reading)
    #expect(model.state == .loading)

    let rows = [try Self.book(1, position: 0), try Self.episode(2, position: 1)]
    reading.push(rows)
    await waitUntil { model.items == rows }
    #expect(model.state == .loaded)
    #expect(model.items.map(\.identity) == rows.map(\.identity))

    reading.push([])
    await waitUntil { model.state == .empty }
    #expect(model.state.copyText.isEmpty == false)
  }

  @MainActor
  @Test("all edit intents forward exactly once")
  func editsForwardOnce() async throws {
    let store = FakeListeningQueueStoring()
    let model = ListeningQueueModel(reading: FakeListeningQueueReading(), storing: store)
    let book = try #require(ListeningIdentity.audiobook(itemID: "book"))
    let firstEpisode = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "one"))

    await model.append(identity: book)
    await model.insertNext(identity: firstEpisode)
    await model.remove(rowID: 7)
    await model.move(rowID: 9, to: 2)

    #expect(
      store.calls == [
        .append(book),
        .insertNext(firstEpisode),
        .removeRow(7),
        .move(9, 2),
      ])
  }

  @MainActor
  @Test("a failed edit reports a bounded error and never optimistically mutates the projection")
  func failedEditReportsBoundedError() async throws {
    let reading = FakeListeningQueueReading()
    let store = FakeListeningQueueStoring()
    let model = ListeningQueueModel(reading: reading, storing: store)
    let rows = [try Self.book(1, position: 0), try Self.episode(2, position: 1)]
    reading.push(rows)
    await waitUntil { model.items == rows }

    store.failNext(ListeningQueueStoreError.restoreTokenStale)
    await model.remove(rowID: rows[0].id)

    #expect(model.items == rows)
    #expect(model.actionErrorMessage == ListeningQueueCopy.editFailed)

    reading.push([])
    await waitUntil { model.state == .empty }
    #expect(model.actionErrorMessage == nil, "a later observed commit clears the bounded error")
  }

  @MainActor
  @Test("clear retains the restore token as a live undo offer")
  func clearRetainsUndoOffer() async {
    let store = FakeListeningQueueStoring()
    let model = ListeningQueueModel(reading: FakeListeningQueueReading(), storing: store)
    #expect(model.canUndoClear == false)

    await model.clear()

    #expect(model.canUndoClear)
    #expect(store.calls == [.clear])
    #expect(model.actionErrorMessage == nil)
  }

  @MainActor
  @Test("undo restores the cleared queue exactly once and retires the offer")
  func undoRestoresAndRetiresOffer() async {
    let store = FakeListeningQueueStoring()
    let model = ListeningQueueModel(reading: FakeListeningQueueReading(), storing: store)

    await model.clear()
    await model.undoClear()

    #expect(store.calls == [.clear, .restore])
    #expect(model.canUndoClear == false)
    #expect(model.actionErrorMessage == nil)

    await model.undoClear()
    #expect(store.calls == [.clear, .restore], "a consumed offer cannot restore twice")
  }

  @MainActor
  @Test("the undo offer expires exactly at the injected ten-second boundary")
  func undoOfferExpiresAtTheBoundary() async {
    let clock = FakeSyncClock(now: Date(timeIntervalSince1970: 1_000))
    let store = FakeListeningQueueStoring()
    let model = ListeningQueueModel(
      reading: FakeListeningQueueReading(), storing: store, clock: clock)

    await model.clear()
    clock.advance(by: ListeningQueueModel.clearUndoLifetime - 0.001)
    #expect(model.canUndoClear)

    clock.advance(by: 0.001)
    #expect(model.canUndoClear == false, "the offer expires at exactly the named lifetime")

    await model.undoClear()
    #expect(store.calls == [.clear], "an expired offer restores nothing")
    #expect(model.actionErrorMessage == ListeningQueueCopy.undoFailed)
  }

  @MainActor
  @Test("an intervening queue mutation invalidates the undo offer immediately")
  func interveningMutationInvalidatesUndoOffer() async throws {
    let store = FakeListeningQueueStoring()
    let model = ListeningQueueModel(reading: FakeListeningQueueReading(), storing: store)
    let book = try #require(ListeningIdentity.audiobook(itemID: "book"))

    await model.clear()
    #expect(model.canUndoClear)
    await model.append(identity: book)
    #expect(model.canUndoClear == false)

    await model.undoClear()
    #expect(store.calls == [.clear, .append(book)])
    #expect(model.actionErrorMessage == ListeningQueueCopy.undoFailed)
  }

  @MainActor
  @Test("a stale restore surfaces a bounded error and restores nothing")
  func staleRestoreReportsBoundedError() async throws {
    let reading = FakeListeningQueueReading()
    let store = FakeListeningQueueStoring()
    let model = ListeningQueueModel(reading: reading, storing: store)
    let rows = [try Self.book(1, position: 0)]
    reading.push(rows)
    await waitUntil { model.items == rows }

    await model.clear()
    store.failNext(ListeningQueueStoreError.restoreTokenStale)
    await model.undoClear()

    #expect(model.actionErrorMessage == ListeningQueueCopy.undoFailed)
    #expect(model.items == rows, "a failed restore never rebuilds the projection itself")
    #expect(model.canUndoClear == false)
  }

  @MainActor
  @Test("deinit cancels the queue observation")
  func deinitCancelsObservation() async {
    let reading = FakeListeningQueueReading()
    var model: ListeningQueueModel? = ListeningQueueModel(reading: reading)
    #expect(model?.state == .loading)
    model = nil
    await waitUntil { reading.isCancelled }
  }

  private static func book(_ id: Int64, position: Int) throws -> ListeningQueueItem {
    let identity = try #require(ListeningIdentity.audiobook(itemID: "book-\(id)"))
    return ListeningQueueItem(
      id: id, position: position, identity: identity,
      primaryTitle: "Book \(id)", secondaryTitle: "Author", category: .audiobook,
      isTombstone: false)
  }

  private static func episode(_ id: Int64, position: Int) throws -> ListeningQueueItem {
    let identity = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show", episodeID: "episode-\(id)"))
    return ListeningQueueItem(
      id: id, position: position,
      identity: identity,
      primaryTitle: "Episode \(id)", secondaryTitle: "Show", category: .podcast,
      isTombstone: false)
  }
}

private final class FakeListeningQueueReading: ListeningQueueReading, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: AsyncStream<[ListeningQueueItem]>.Continuation?
  private(set) var isCancelled = false

  func observeQueue() -> AsyncStream<[ListeningQueueItem]> {
    AsyncStream { continuation in
      lock.withLock { self.continuation = continuation }
      continuation.onTermination = { [weak self] _ in
        self?.lock.withLock { self?.isCancelled = true }
      }
    }
  }

  func push(_ items: [ListeningQueueItem]) {
    lock.withLock { continuation }?.yield(items)
  }
}

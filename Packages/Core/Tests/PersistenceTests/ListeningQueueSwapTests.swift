import Foundation
import GRDB
import Testing

@testable import Persistence

/// A swap consumes the started row and returns the title it displaced to the front of Up Next, in
/// one write, so neither half can land without the other.
@Suite struct ListeningQueueSwapTests {
  private typealias Seed = ListeningQueueChapterStoreTests
  private static let one = ListeningQueueChapter(start: 0, end: 300, title: "One")

  private static func store() async throws -> (ListeningQueueStore, Seed.Fixture) {
    let database = try AppDatabase.inMemory()
    let fixture = try await Seed.seed(database)
    return (ListeningQueueStore(database: database, accountId: fixture.accountId), fixture)
  }

  @Test("the started row goes and the displaced title takes the front")
  func swapReturnsTheDisplacedTitleToTheFront() async throws {
    let (store, fixture) = try await Self.store()
    try await store.append(identity: fixture.episode)
    try await store.append(identity: fixture.rssEpisode)

    let requeued = try await store.acknowledgeStarted(
      identity: fixture.episode, rowID: nil, returning: fixture.book)

    #expect(requeued)
    let queue = await store.fetchQueue()
    #expect(queue.map(\.identity) == [fixture.book, fixture.rssEpisode])
    #expect(queue.map(\.chapter) == [nil, nil])
    #expect(queue.map(\.position) == [0, 1])
  }

  @Test("a swap from a later row still returns the displaced title to the front")
  func swapFromALaterRow() async throws {
    let (store, fixture) = try await Self.store()
    try await store.append(identity: fixture.rssEpisode)
    try await store.append(identity: fixture.episode)

    try await store.acknowledgeStarted(identity: fixture.episode, rowID: nil, returning: fixture.book)

    #expect(await store.fetchQueue().map(\.identity) == [fixture.book, fixture.rssEpisode])
  }

  @Test("a displaced title already queued whole moves to the front rather than doubling")
  func displacedTitleAlreadyQueuedWholeMoves() async throws {
    let (store, fixture) = try await Self.store()
    try await store.append(identity: fixture.episode)
    try await store.append(identity: fixture.rssEpisode)
    try await store.append(identity: fixture.book)
    let bookRow = try #require(await store.fetchQueue().last?.id)

    let requeued = try await store.acknowledgeStarted(
      identity: fixture.episode, rowID: nil, returning: fixture.book)

    #expect(requeued)
    let queue = await store.fetchQueue()
    #expect(queue.map(\.identity) == [fixture.book, fixture.rssEpisode])
    #expect(queue.first?.id == bookRow)
  }

  @Test("a displaced book with queued chapter rows keeps them and gains no whole-book row")
  func displacedBookWithChapterRowsIsLeftAlone() async throws {
    let (store, fixture) = try await Self.store()
    try await store.append(identity: fixture.episode)
    try await store.append(identity: fixture.book, chapter: Self.one)

    let requeued = try await store.acknowledgeStarted(
      identity: fixture.episode, rowID: nil, returning: fixture.book)

    #expect(requeued == false)
    let queue = await store.fetchQueue()
    #expect(queue.map(\.identity) == [fixture.book])
    #expect(queue.map(\.chapter) == [Self.one])
  }

  @Test("a displaced title the queue cannot hold is skipped and the start is still consumed")
  func unqueueableDisplacedTitleStillConsumesTheStart() async throws {
    let (store, fixture) = try await Self.store()
    try await store.append(identity: fixture.episode)
    try await store.append(identity: fixture.rssEpisode)
    let missing = try #require(ListeningIdentity.audiobook(itemID: "not-in-library"))

    let requeued = try await store.acknowledgeStarted(
      identity: fixture.episode, rowID: nil, returning: missing)

    #expect(requeued == false)
    #expect(await store.fetchQueue().map(\.identity) == [fixture.rssEpisode])
  }

  @Test("a swap names the started chapter row like any start, leaving the book's other chapters")
  func swapConsumesOnlyTheStartedChapterRow() async throws {
    let (store, fixture) = try await Self.store()
    let two = ListeningQueueChapter(start: 300, end: 600, title: "Two")
    try await store.append(identity: fixture.book, chapter: Self.one)
    try await store.append(identity: fixture.book, chapter: two)
    let rows = await store.fetchQueue()

    try await store.acknowledgeStarted(
      identity: fixture.book, rowID: rows[0].id, returning: fixture.episode)

    let queue = await store.fetchQueue()
    #expect(queue.map(\.identity) == [fixture.episode, fixture.book])
    #expect(queue.map(\.chapter) == [nil, two])
  }
}

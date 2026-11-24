import Foundation
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// Swapping Now Playing with an Up Next row: the row plays now, and the title it displaced returns
/// to the front of Up Next once, and only once, the start has succeeded.
@Suite(.timeLimit(.minutes(1)))
struct UpNextSwapPlaybackModelTests {
  private typealias World = SmartListRunPlaybackModelTests.World
  private typealias Fixture = SmartListRunPlaybackModelTests

  @MainActor
  @Test("the row plays now and the displaced book takes the front of Up Next")
  func swapReturnsTheBookToTheFront() async throws {
    let world = Fixture.makeWorld()
    let book = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let a = Fixture.identity("a")
    let b = Fixture.identity("b")
    try await Self.playBook(world)
    await world.queue.configure(rows: [Fixture.row(1, a), Fixture.row(2, b)])

    world.sync.stubStartSession(.success(Fixture.prepared("show", "a")))
    await world.model.swap(toQueueItem: Fixture.row(1, a))

    #expect(world.model.loadedItemID == "show")
    #expect(world.model.loadedEpisodeID == "a")
    #expect(await world.queue.returned == [book])
    #expect(await world.queue.identities.first == book)
    #expect(await world.queue.identities.contains(a) == false)
  }

  @MainActor
  @Test("when the swapped-in episode ends, the book resumes next")
  func bookPlaysAfterTheSwappedEpisode() async throws {
    let world = Fixture.makeWorld()
    let a = Fixture.identity("a")
    try await Self.playBook(world)
    await world.queue.configure(rows: [Fixture.row(1, a)])
    world.sync.stubStartSession(.success(Fixture.prepared("show", "a")))
    await world.model.swap(toQueueItem: Fixture.row(1, a))

    world.sync.stubStartSession(.success(Fixture.prepared("book-1")))
    world.player.pushProgress(Fixture.ended("show", "a"))
    await world.queue.waitForAcknowledgements(4)

    #expect(world.model.loadedItemID == "book-1")
    #expect(world.model.loadedEpisodeID == nil)
    #expect(await world.queue.identities.isEmpty)
  }

  @MainActor
  @Test("a failed start returns nothing and leaves the row where it was")
  func failedSwapReturnsNothing() async throws {
    let world = Fixture.makeWorld()
    let a = Fixture.identity("a")
    try await Self.playBook(world)
    await world.queue.configure(rows: [Fixture.row(1, a)])

    world.sync.stubStartSession(.failure(ListeningQueueFixtureFailure.failed))
    await world.model.swap(toQueueItem: Fixture.row(1, a))

    #expect(await world.queue.returned.isEmpty)
    #expect(await world.queue.identities == [a])
  }

  @MainActor
  @Test("with nothing playing, a swap is a plain start")
  func swapWithNothingPlayingIsAPlainStart() async throws {
    let world = Fixture.makeWorld()
    let a = Fixture.identity("a")
    await world.queue.configure(rows: [Fixture.row(1, a)])

    world.sync.stubStartSession(.success(Fixture.prepared("show", "a")))
    await world.model.swap(toQueueItem: Fixture.row(1, a))
    await world.queue.waitForAcknowledgements(1)

    #expect(world.model.loadedEpisodeID == "a")
    #expect(await world.queue.returned.isEmpty)
    #expect(await world.queue.acknowledged == [a])
  }

  @MainActor
  @Test("a swap ends an active list run, and the displaced list episode plays next from Up Next")
  func swapEndsTheListRun() async throws {
    let world = Fixture.makeWorld()
    let book = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let a = Fixture.identity("a")
    await world.continuation.configure(run: Fixture.run(anchor: "a"), next: [Fixture.candidate("b")])
    world.sync.stubStartSession(.success(Fixture.prepared("show", "a")))
    await world.model.start(itemID: "show", episodeID: "a")
    await world.queue.configure(rows: [Fixture.row(1, book)])

    world.sync.stubStartSession(.success(Fixture.prepared("book-1")))
    await world.model.swap(toQueueItem: Fixture.row(1, book))

    #expect(await world.continuation.hasRun == false, "the swap ends the run (ADR 0016)")
    #expect(await world.queue.identities == [a])

    world.sync.stubStartSession(.success(Fixture.prepared("show", "a")))
    world.player.pushProgress(Fixture.ended("book-1"))
    await world.queue.waitForAcknowledgements(4)

    #expect(world.model.loadedEpisodeID == "a", "Up Next's head, not the list's next episode")
  }

  @MainActor
  private static func playBook(_ world: World) async throws {
    world.sync.stubStartSession(.success(Fixture.prepared("book-1")))
    await world.model.start(itemID: "book-1")
    await world.queue.waitForAcknowledgements(1)
    #expect(world.model.nowPlayingIdentity == ListeningIdentity.audiobook(itemID: "book-1"))
  }
}

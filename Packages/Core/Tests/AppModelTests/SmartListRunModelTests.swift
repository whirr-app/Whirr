import Foundation
import Persistence
import TestSupport
import Testing

@testable import AppModel

@MainActor
@Suite("SmartListRunModel", .timeLimit(.minutes(1)))
struct SmartListRunModelTests {
  private struct World {
    let fixture: SmartListFixture
    let continuation: SmartListContinuation
    let model: SmartListRunModel
    let listID: Int64
    let feed: Int64
  }

  /// A list over one native feed with `keys` newest first, and a model over the same services.
  private func world(
    nativeEnabled: Bool = true, keys: [String] = ["e1", "e2", "e3", "e4", "e5"]
  ) async throws -> World {
    let fixture = try SmartListFixture(nativeEnabled: nativeEnabled)
    let feed = try await fixture.feed("https://a.example/feed", title: "Show A")
    for (offset, key) in keys.enumerated() {
      try await fixture.episode(feed: feed, key, ageSeconds: Double(offset + 1) * 3_600)
    }
    let list = try await fixture.services.store.create(name: "Commute")
    let continuation = SmartListContinuation(
      runs: fixture.services.runs,
      reading: { fixture.services.makeReading(nativeEnabled) },
      hasAvailableSource: { nativeEnabled })
    let model = SmartListRunModel(services: fixture.services, continuation: continuation)
    return World(
      fixture: fixture, continuation: continuation, model: model, listID: list.id, feed: feed)
  }

  @Test("no run row means no run")
  func noRun() async throws {
    let world = try await world()
    await awaitQuiescence("the run observation settles") { String(describing: world.model.run) }
    #expect(world.model.run == nil)
    #expect(world.model.activeListName == nil)
  }

  @Test("a run reports its list and the next three episodes after the anchor, never the anchor")
  func nextThree() async throws {
    let world = try await world()
    #expect(
      await world.continuation.recordListStart(
        itemID: world.fixture.nativeItemID(world.feed), episodeID: "e2", listID: world.listID))
    #expect(
      await waitUntil("run with upcoming") {
        world.model.run?.upcoming.map(\.episodeID) == ["e3", "e4", "e5"]
      })
    #expect(world.model.run?.listName == "Commute")
    #expect(world.model.run?.listID == world.listID)
    #expect(world.model.run?.upcoming.first?.title == "T-e3")
    #expect(world.model.run?.upcoming.first?.showTitle == "Show A")
    #expect(world.model.activeListName == "Commute")
  }

  @Test("a rename, a new anchor and a finished episode all update the preview")
  func updates() async throws {
    let world = try await world()
    let itemID = world.fixture.nativeItemID(world.feed)
    _ = await world.continuation.recordListStart(
      itemID: itemID, episodeID: "e1", listID: world.listID)
    #expect(
      await waitUntil("initial") {
        world.model.run?.upcoming.map(\.episodeID) == ["e2", "e3", "e4"]
      })

    try await world.fixture.services.store.rename(id: world.listID, to: "Drive")
    #expect(await waitUntil("renamed") { world.model.run?.listName == "Drive" })

    _ = await world.continuation.recordListStart(
      itemID: itemID, episodeID: "e2", listID: nil)
    #expect(
      await waitUntil("anchor moved") {
        world.model.run?.upcoming.map(\.episodeID) == ["e3", "e4", "e5"]
      })
  }

  @Test("stop ends the run through the continuation and clears the model")
  func stop() async throws {
    let world = try await world()
    _ = await world.continuation.recordListStart(
      itemID: world.fixture.nativeItemID(world.feed), episodeID: "e1", listID: world.listID)
    #expect(await waitUntil("active") { world.model.run != nil })

    await world.model.stop()
    #expect(world.model.run == nil)
    #expect(try await world.fixture.services.runs.current() == nil)
  }

  @Test("deleting the list ends the run")
  func deletedList() async throws {
    let world = try await world()
    _ = await world.continuation.recordListStart(
      itemID: world.fixture.nativeItemID(world.feed), episodeID: "e1", listID: world.listID)
    #expect(await waitUntil("active") { world.model.run != nil })

    try await world.fixture.services.store.delete(id: world.listID)
    #expect(await waitUntil("cleared") { world.model.run == nil })
  }

  @Test("a run whose list has no available source is reported as no run, like currentRun")
  func noAvailableSource() async throws {
    let world = try await world()
    _ = await world.continuation.recordListStart(
      itemID: world.fixture.nativeItemID(world.feed), episodeID: "e1", listID: world.listID)
    #expect(await waitUntil("active") { world.model.run != nil })

    await world.fixture.preference.setEnabled(false)
    #expect(await waitUntil("hidden while no source") { world.model.run == nil })
    // The row stays, exactly as `currentRun()` leaves it.
    #expect(try await world.fixture.services.runs.current() != nil)

    await world.fixture.preference.setEnabled(true)
    #expect(await waitUntil("back with the source") { world.model.run != nil })
  }

  @Test("the inactive model never reports a run and stop is harmless")
  func inactive() async {
    let model = SmartListRunModel()
    #expect(model.run == nil)
    await model.stop()
    #expect(model.activeListName == nil)
  }
}

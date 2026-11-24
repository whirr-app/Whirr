import Foundation
import Persistence
import TestSupport
import Testing

@testable import AppModel

@MainActor
@Suite("SmartListsModel")
struct SmartListsModelTests {
  @Test("shows when native is on, even signed out")
  func availableWithNativeOnly() async throws {
    let fixture = try SmartListFixture(nativeEnabled: true)
    let model = SmartListsModel(services: fixture.services)
    #expect(await waitUntil("loaded") { model.state == .loaded })
    #expect(model.isAvailable)
  }

  @Test("native off and signed out is unavailable, and becomes available on sign-in")
  func availabilityFollowsSources() async throws {
    let fixture = try SmartListFixture(nativeEnabled: false)
    let model = SmartListsModel(services: fixture.services)
    #expect(await waitUntil("unavailable") { model.state == .unavailable })
    #expect(model.isAvailable == false)
    #expect(model.lists.isEmpty)

    try await fixture.signIn()
    #expect(await waitUntil("available with an account") { model.state == .loaded })

    try await fixture.signOut()
    #expect(await waitUntil("unavailable again") { model.state == .unavailable })

    await fixture.preference.setEnabled(true)
    #expect(await waitUntil("available with native") { model.state == .loaded })
  }

  @Test("native off empties the native half of a list's count")
  func nativeOffEmptiesNativeHalf() async throws {
    let fixture = try SmartListFixture(nativeEnabled: true)
    let feed = try await fixture.feed("https://a.example/feed")
    try await fixture.episode(feed: feed, "e1")
    try await fixture.signIn()
    let model = SmartListsModel(services: fixture.services)
    await model.create(name: "All")
    #expect(await waitUntil("one match") { model.lists.first?.matchCount == 1 })

    await fixture.preference.setEnabled(false)
    #expect(await waitUntil("zero matches without native") { model.lists.first?.matchCount == 0 })
  }

  @Test("create lists the new list with its match count and next episode")
  func createShowsCountAndNext() async throws {
    let fixture = try SmartListFixture()
    let feed = try await fixture.feed("https://a.example/feed", title: "Show A")
    try await fixture.episode(feed: feed, "old", ageSeconds: 3_600)
    try await fixture.episode(feed: feed, "new", ageSeconds: 60)
    let model = SmartListsModel(services: fixture.services)
    #expect(await waitUntil("loaded") { model.state == .loaded })

    let list = await model.create(name: "  Commute  ")
    #expect(list?.name == "Commute")
    #expect(
      await waitUntil("summary") {
        model.lists.first?.matchCount == 2 && model.lists.first?.nextEpisodeTitle == "T-new"
      })
    #expect(model.lists.first?.nextShowTitle == "Show A")
    #expect(model.lists.first?.isActive == false)
  }

  @Test("a summary carries one cover per show, in list order")
  func summaryCovers() async throws {
    let fixture = try SmartListFixture()
    let a = try await fixture.feed("https://a.example/feed", title: "Show A")
    let b = try await fixture.feed("https://b.example/feed", title: "Show B")
    try await fixture.episode(feed: a, "a1", ageSeconds: 60)
    try await fixture.episode(feed: a, "a2", ageSeconds: 120)
    try await fixture.episode(feed: b, "b1", ageSeconds: 180)
    let model = SmartListsModel(services: fixture.services)
    #expect(await waitUntil("loaded") { model.state == .loaded })

    await model.create(name: "All")
    #expect(
      await waitUntil("covers") {
        model.lists.first?.coverEpisodes.map(\.showTitle) == ["Show A", "Show B"]
      })
  }

  @Test("the episode Play starts is the list's first unfinished one")
  func firstPlayable() async throws {
    let fixture = try SmartListFixture()
    let feed = try await fixture.feed("https://a.example/feed")
    try await fixture.episode(feed: feed, "old", ageSeconds: 3_600)
    try await fixture.episode(feed: feed, "new", ageSeconds: 60)
    let model = SmartListsModel(services: fixture.services)
    #expect(await waitUntil("loaded") { model.state == .loaded })
    let list = try #require(await model.create(name: "All"))

    #expect(await model.firstPlayable(listID: list.id)?.episode.title == "T-new")
  }

  @Test("the next episode skips a finished one")
  func nextSkipsFinished() async throws {
    let fixture = try SmartListFixture()
    let feed = try await fixture.feed("https://a.example/feed")
    let newest = try await fixture.episode(feed: feed, "new", ageSeconds: 60)
    try await fixture.episode(feed: feed, "old", ageSeconds: 3_600)
    try await fixture.finish(newest)
    let model = SmartListsModel(services: fixture.services)
    await model.create(name: "L", rules: SmartListRules(includePlayed: true))
    #expect(
      await waitUntil("next is the unfinished one") {
        model.lists.first?.nextEpisodeTitle == "T-old"
      })
  }

  @Test("create starts expansion of the new list")
  func createExpands() async throws {
    let fixture = try SmartListFixture()
    let model = SmartListsModel(services: fixture.services)
    let list = try #require(await model.create(name: "L"))
    #expect(await waitUntil("expanded") { fixture.expansions.listIDs == [list.id] })
  }

  @Test("the active run's list is marked")
  func activeRunMarked() async throws {
    let fixture = try SmartListFixture()
    let model = SmartListsModel(services: fixture.services)
    let first = try #require(await model.create(name: "A"))
    let second = try #require(await model.create(name: "B"))
    #expect(model.activeListID == nil)

    try await SmartListRunStore(database: fixture.database).begin(listID: second.id)
    await model.reload()
    // The run is also observed, and that stream's first value can land after the reload.
    #expect(
      await waitUntil("second marked") {
        model.activeListID == second.id && model.lists.map(\.isActive) == [false, true]
      })

    await model.delete(id: second.id)
    #expect(
      await waitUntil("second gone") {
        model.activeListID == nil && model.lists.map(\.id) == [first.id]
      })
  }

  @Test("an injected run observation drives the active list")
  func injectedRunObservation() async throws {
    let fixture = try SmartListFixture()
    let (stream, continuation) = AsyncStream.makeStream(of: Int64?.self)
    let services = SmartListServices(
      database: fixture.database, subscriptions: fixture.preference,
      accountIdentity: DefaultAccountIdentityReading(database: fixture.database),
      observeActiveRunListID: { stream })
    let model = SmartListsModel(services: services)
    let list = try #require(await model.create(name: "A"))
    continuation.yield(list.id)
    #expect(await waitUntil("active") { model.activeListID == list.id })
    continuation.yield(nil)
    #expect(await waitUntil("inactive") { model.activeListID == nil })
  }

  @Test("delete removes a list and closes the order up")
  func deleteClosesUp() async throws {
    let fixture = try SmartListFixture()
    let model = SmartListsModel(services: fixture.services)
    let a = try #require(await model.create(name: "A"))
    let b = try #require(await model.create(name: "B"))
    let c = try #require(await model.create(name: "C"))
    await model.delete(id: b.id)
    #expect(model.lists.map(\.id) == [a.id, c.id])
    let positions = try await SmartListStore(database: fixture.database).lists().map(\.position)
    #expect(positions == [0, 1])
  }

  @Test("delete goes through the injected delete, which releases the list's downloads")
  func deleteUsesInjectedDelete() async throws {
    let fixture = try SmartListFixture()
    let deleted = DeletedLists()
    let store = SmartListStore(database: fixture.database)
    let services = SmartListServices(
      database: fixture.database, subscriptions: fixture.preference,
      accountIdentity: DefaultAccountIdentityReading(database: fixture.database),
      deleteList: { id in
        deleted.record(id)
        try await store.delete(id: id)
      })
    let model = SmartListsModel(services: services)
    let list = try #require(await model.create(name: "A"))
    await model.delete(id: list.id)
    #expect(deleted.ids == [list.id])
    #expect(model.lists.isEmpty)
  }

  @Test("reorder stores the new order, and a wrong id set is an error")
  func reorder() async throws {
    let fixture = try SmartListFixture()
    let model = SmartListsModel(services: fixture.services)
    let a = try #require(await model.create(name: "A"))
    let b = try #require(await model.create(name: "B"))
    let c = try #require(await model.create(name: "C"))

    await model.reorder(ids: [c.id, a.id, b.id])
    #expect(model.lists.map(\.id) == [c.id, a.id, b.id])
    #expect(model.error == nil)

    await model.reorder(ids: [a.id])
    #expect(model.error == .reorderFailed)
    #expect(model.lists.map(\.id) == [c.id, a.id, b.id])

    await model.move(id: b.id, toPosition: 0)
    #expect(model.lists.map(\.id) == [b.id, c.id, a.id])
  }

  @Test("the fifty-first list surfaces as an error, not a crash")
  func listCap() async throws {
    let fixture = try SmartListFixture()
    let store = SmartListStore(database: fixture.database)
    for index in 0..<SmartListStore.maximumListCount { try await store.create(name: "L\(index)") }
    let model = SmartListsModel(services: fixture.services)
    #expect(await waitUntil("loaded") { model.lists.count == 50 })
    #expect(model.canCreate == false)

    let created = await model.create(name: "One too many")
    #expect(created == nil)
    #expect(model.error == .listLimitReached)
    #expect(model.error?.message == SmartListsCopy.listLimitReached)
    #expect(model.lists.count == 50)

    await model.delete(id: try #require(model.lists.first?.id))
    #expect(model.canCreate)
    #expect(await model.create(name: "Now it fits") != nil)
    #expect(model.error == nil)
  }

  @Test("an invalid name is a create failure")
  func invalidName() async throws {
    let fixture = try SmartListFixture()
    let model = SmartListsModel(services: fixture.services)
    #expect(await model.create(name: "   ") == nil)
    #expect(model.error == .createFailed)
  }

  @Test("a list created or renamed elsewhere reaches the model")
  func changesElsewherePush() async throws {
    let fixture = try SmartListFixture()
    let model = SmartListsModel(services: fixture.services)
    #expect(await waitUntil("loaded") { model.state == .loaded })
    let list = try await fixture.services.store.create(name: "Made elsewhere")
    #expect(await waitUntil("created") { model.lists.map(\.name) == ["Made elsewhere"] })
    try await fixture.services.store.rename(id: list.id, to: "Renamed")
    #expect(await waitUntil("renamed") { model.lists.map(\.name) == ["Renamed"] })
  }
}

private final class DeletedLists: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [Int64] = []
  func record(_ id: Int64) { lock.withLock { stored.append(id) } }
  var ids: [Int64] { lock.withLock { stored } }
}

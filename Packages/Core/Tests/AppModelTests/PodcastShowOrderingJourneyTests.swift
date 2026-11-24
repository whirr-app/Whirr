import Foundation
import GRDB
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// Composed journeys: the real `DefaultPodcastShowOrdering` and `PodcastShowsModel` over a real
/// GRDB database, driven through the `apply(order:)`/`move(itemID:to:)` funnel that
/// `PodcastShowsView`'s drop delegate and accessibility actions call. The individual rules are
/// pinned by `PodcastShowOrderingTests` and `PodcastShowsModelTests`; this file covers the
/// lifecycle: first drag, relaunch, a newly synced show, soft deletion, revival, reset, logout.
///
/// Shows arrive by seeding `item` rows: the ordering query reads only `item`, so a seeded row is
/// indistinguishable from a synced one.
///
/// `.serialized` because parallel `@MainActor` model tests add main-actor pressure that suites
/// polling on a wall-clock deadline pay for.
@MainActor
@Suite("Podcast show ordering journeys", .serialized, .timeLimit(.minutes(1)))
struct PodcastShowOrderingJourneyTests {

  /// `PodcastsViewPresentation.previewLimit`'s value, restated here because the App target is above
  /// Core. The assertion that matters is that the preview is a strict prefix of the page order.
  private static let previewLimit = 6

  @Test(
    "a migrated account starts alphabetical; one cross-row drag makes both the page and the six-show preview custom"
  )
  func migratedAccountStartsAlphabeticalUntilTheFirstDragCommitsCustomOrder() async throws {
    let env = try await PodcastShowOrderingJourneyEnvironment.make()
    try await env.seedEightShows()
    let model = env.makeModel()

    // A migrated account has no `podcastShowOrder` row at all (alphabetical is never persisted),
    // so the very first render is alphabetical.
    await env.waitUntilMainActor { model.shows.isEmpty == false }
    #expect(model.sortMode == .alphabetical)
    #expect(model.shows.map(\.serverItemId) == PodcastShowOrderingJourneyEnvironment.alphabetical)
    #expect(
      model.preview(limit: Self.previewLimit)
        .map(\.serverItemId) == Array(PodcastShowOrderingJourneyEnvironment.alphabetical.prefix(6)))
    #expect(model.isEditingAllowed, "a settled, non-empty page is editable")

    // Edit → drag the last tile to the front. With the adaptive grid at any column count this
    // crosses rows; the view commits the working order its drop delegate produced.
    var dragged = PodcastShowOrderingJourneyEnvironment.alphabetical
    let moved = dragged.removeLast()
    dragged.insert(moved, at: 0)
    await model.apply(order: dragged)

    // Done → the page and the preview both come from the one durable snapshot.
    await env.waitUntilMainActor { model.sortMode == .custom }
    #expect(model.actionErrorMessage == nil)
    #expect(model.shows.map(\.serverItemId) == dragged)
    #expect(model.preview(limit: Self.previewLimit).map(\.serverItemId) == Array(dragged.prefix(6)))
    #expect(try await env.entries() == dragged.enumerated().map { "\($1):\($0)" })
  }

  @Test("relaunching over the same database preserves the page and preview order")
  func relaunchPreservesThePageAndPreviewOrder() async throws {
    let env = try await PodcastShowOrderingJourneyEnvironment.make()
    try await env.seedEightShows()
    let custom = PodcastShowOrderingJourneyEnvironment.alphabetical.reversed().map { $0 }
    do {
      let model = env.makeModel()
      await env.waitUntilMainActor { model.shows.isEmpty == false }
      await model.apply(order: custom)
      await env.waitUntilMainActor { model.sortMode == .custom }
    }

    let relaunched = env.makeRelaunchedModel()
    await env.waitUntilMainActor { relaunched.shows.isEmpty == false }
    #expect(relaunched.sortMode == .custom)
    #expect(relaunched.shows.map(\.serverItemId) == custom)
    #expect(
      relaunched.preview(limit: Self.previewLimit).map(\.serverItemId) == Array(custom.prefix(6)))
  }

  @Test("a show synced after a custom order appends after every positioned show")
  func aNewlySyncedShowAppendsAfterThePositionedShows() async throws {
    let env = try await PodcastShowOrderingJourneyEnvironment.make()
    try await env.seedEightShows()
    let model = env.makeModel()
    await env.waitUntilMainActor { model.shows.isEmpty == false }

    let custom = PodcastShowOrderingJourneyEnvironment.alphabetical.reversed().map { $0 }
    await model.apply(order: custom)
    await env.waitUntilMainActor { model.sortMode == .custom }

    // A sortTitle that would sort first alphabetically, so this can only pass if unpositioned
    // shows are appended rather than merged into the sequence (the left join).
    try await env.seedShow(id: "show-new", sortTitle: "aaaa-new")
    await env.waitUntilMainActor { model.shows.count == custom.count + 1 }

    #expect(model.shows.map(\.serverItemId) == custom + ["show-new"])
    #expect(model.sortMode == .custom)
  }

  @Test("a soft-deleted show leaves the page without shifting any persisted position")
  func softDeleteRemovesAShowWithoutShiftingPersistedIdentities() async throws {
    let env = try await PodcastShowOrderingJourneyEnvironment.make()
    try await env.seedEightShows()
    let model = env.makeModel()
    await env.waitUntilMainActor { model.shows.isEmpty == false }

    let custom = PodcastShowOrderingJourneyEnvironment.alphabetical.reversed().map { $0 }
    await model.apply(order: custom)
    await env.waitUntilMainActor { model.sortMode == .custom }
    let persisted = try await env.entries()

    try await env.setSoftDeleted(id: "show-d", softDeleted: true)
    await env.waitUntilMainActor { model.shows.count == custom.count - 1 }

    #expect(model.shows.map(\.serverItemId) == custom.filter { $0 != "show-d" })
    #expect(
      try await env.entries() == persisted,
      "deletion inference is reversible, so it must never renumber the durable order")
  }

  @Test("a reorder made while a show is absent drops its position, and reviving it appends the show")
  func aReorderWhileAShowIsAbsentDropsItsPositionAndRevivalAppendsIt() async throws {
    let env = try await PodcastShowOrderingJourneyEnvironment.make()
    try await env.seedEightShows()
    let model = env.makeModel()
    await env.waitUntilMainActor { model.shows.isEmpty == false }

    let custom = PodcastShowOrderingJourneyEnvironment.alphabetical.reversed().map { $0 }
    await model.apply(order: custom)
    await env.waitUntilMainActor { model.sortMode == .custom }

    try await env.setSoftDeleted(id: "show-d", softDeleted: true)
    await env.waitUntilMainActor { model.shows.contains { $0.serverItemId == "show-d" } == false }

    // The user rearranges while it is gone, using an accessibility Move Later this time, through
    // the same funnel the drag uses. The replacement is the current live sequence, so the absent
    // show's old position is dropped.
    let live = model.shows.map(\.serverItemId)
    await model.move(itemID: live[0], to: 1)
    await env.waitUntilMainActor { model.shows.map(\.serverItemId) != live }
    #expect(model.actionErrorMessage == nil)
    let rearranged = model.shows.map(\.serverItemId)
    #expect(try await env.entries() == rearranged.enumerated().map { "\($1):\($0)" })

    try await env.setSoftDeleted(id: "show-d", softDeleted: false)
    await env.waitUntilMainActor { model.shows.count == rearranged.count + 1 }
    #expect(model.shows.map(\.serverItemId) == rearranged + ["show-d"])
  }

  @Test("reset returns the page and the preview to alphabetical and clears every stored row")
  func resetReturnsThePageAndPreviewToAlphabetical() async throws {
    let env = try await PodcastShowOrderingJourneyEnvironment.make()
    try await env.seedEightShows()
    let model = env.makeModel()
    await env.waitUntilMainActor { model.shows.isEmpty == false }

    let custom = PodcastShowOrderingJourneyEnvironment.alphabetical.reversed().map { $0 }
    await model.apply(order: custom)
    await env.waitUntilMainActor { model.sortMode == .custom }

    await model.resetToAlphabetical()
    await env.waitUntilMainActor { model.sortMode == .alphabetical }

    #expect(model.actionErrorMessage == nil)
    #expect(model.shows.map(\.serverItemId) == PodcastShowOrderingJourneyEnvironment.alphabetical)
    #expect(
      model.preview(limit: Self.previewLimit)
        .map(\.serverItemId) == Array(PodcastShowOrderingJourneyEnvironment.alphabetical.prefix(6)))
    #expect(try await env.entries().isEmpty)
    #expect(try await env.modeRowCount() == 0)
  }

  @Test("logout removes every stored order row for the account")
  func logoutRemovesEveryStoredOrderRow() async throws {
    let env = try await PodcastShowOrderingJourneyEnvironment.make()
    try await env.seedEightShows()
    let model = env.makeModel()
    await env.waitUntilMainActor { model.shows.isEmpty == false }
    await model.apply(order: PodcastShowOrderingJourneyEnvironment.alphabetical.reversed().map { $0 })
    await env.waitUntilMainActor { model.sortMode == .custom }
    #expect(try await env.entries().isEmpty == false)

    // `AccountRemovalCoordinator`'s durable step, the sweep every logout runs.
    try AccountRemover(database: env.database).removeAccount(accountId: env.accountID)

    #expect(try await env.orderRowCount() == 0)
    #expect(try await env.entryRowCount() == 0)
  }
}

// MARK: - Environment

/// Not `@MainActor`; every database helper is `async` over `writeAsync`/`readAsync`. The tests run
/// on the main actor, and GRDB's synchronous overloads use `dispatch_sync`, which would block it.
private final class PodcastShowOrderingJourneyEnvironment: @unchecked Sendable {
  /// Eight shows so the six-show preview is a strict prefix of the page rather than the whole page.
  static let alphabetical = [
    "show-a", "show-b", "show-c", "show-d", "show-e", "show-f", "show-g", "show-h",
  ]

  let database: AppDatabase
  let accountID: Int64

  private let libraryID: Int64

  private init(database: AppDatabase, accountID: Int64, libraryID: Int64) {
    self.database = database
    self.accountID = accountID
    self.libraryID = libraryID
  }

  static func make() async throws -> PodcastShowOrderingJourneyEnvironment {
    let database = try AppDatabase.inMemory()
    let ids = try await database.writeAsync { db -> (Int64, Int64) in
      var account = AccountRecord(
        clientUUID: "show-ordering-journey-client",
        serverBaseURL: "https://show-ordering-journey.invalid",
        serverUserId: "show-ordering-user", serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "podcast-library", mediaType: "podcast",
        name: "Podcasts")
      try library.insert(db)
      return (account.id!, library.id!)
    }
    return PodcastShowOrderingJourneyEnvironment(
      database: database, accountID: ids.0, libraryID: ids.1)
  }

  @MainActor
  func makeModel() -> PodcastShowsModel {
    PodcastShowsModel(
      ordering: DefaultPodcastShowOrdering(database: database, accountId: accountID),
      library: DefaultLibraryReading(database: database),
      sync: FakeSyncCoordinating())
  }

  /// A fresh store, observation, and model over the durable rows: the deterministic relaunch seam.
  /// That the rows survive closing and reopening the file is
  /// `PodcastShowOrderingTests.relaunchPreservesCustomOrder`'s job; this proves a cold-composed
  /// model reads the order back rather than retaining it.
  @MainActor
  func makeRelaunchedModel() -> PodcastShowsModel {
    makeModel()
  }

  func seedEightShows() async throws {
    for id in Self.alphabetical {
      try await seedShow(id: id, sortTitle: id)
    }
  }

  func seedShow(id: String, sortTitle: String) async throws {
    let accountID = accountID
    let libraryID = libraryID
    try await database.writeAsync { db in
      var item = ItemRecord(
        accountId: accountID, libraryId: libraryID, serverItemId: id, mediaKind: "podcast",
        title: sortTitle, sortTitle: sortTitle)
      try item.insert(db)
    }
  }

  func setSoftDeleted(id: String, softDeleted: Bool) async throws {
    let accountID = accountID
    try await database.writeAsync { db in
      try db.execute(
        sql: "UPDATE item SET softDeleted = ? WHERE accountId = ? AND serverItemId = ?",
        arguments: [softDeleted, accountID, id])
    }
  }

  /// `"<serverItemId>:<position>"` per stored row, in position order: one comparable value that
  /// asserts identity, density, and order together.
  func entries() async throws -> [String] {
    let accountID = accountID
    return try await database.readAsync { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT item.serverItemId AS serverItemId, entry.position AS position
          FROM podcastShowOrderEntry AS entry
          JOIN item ON item.id = entry.itemId AND item.accountId = entry.accountId
          WHERE entry.accountId = ?
          ORDER BY entry.position
          """,
        arguments: [accountID]
      ).map { "\($0["serverItemId"] as String):\($0["position"] as Int)" }
    }
  }

  func modeRowCount() async throws -> Int {
    try await count(in: "podcastShowOrder", forAccount: true)
  }

  func orderRowCount() async throws -> Int {
    try await count(in: "podcastShowOrder", forAccount: false)
  }

  func entryRowCount() async throws -> Int {
    try await count(in: "podcastShowOrderEntry", forAccount: false)
  }

  @MainActor
  func waitUntilMainActor(_ predicate: @escaping @MainActor () -> Bool) async {
    await waitUntil { predicate() }
  }

  private func count(in table: String, forAccount: Bool) async throws -> Int {
    let accountID = accountID
    return try await database.readAsync { db in
      if forAccount {
        return try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM \(table) WHERE accountId = ?", arguments: [accountID]) ?? -1
      }
      return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
    }
  }
}

import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite struct SmartListStoreTests {
  // MARK: - Creation and validation

  @Test func createTrimsTheNameAndAppendsAtTheNextPosition() async throws {
    let (_, store) = try makeStore()
    let first = try await store.create(name: "  Commute \n")
    let second = try await store.create(name: "Gym", rules: .newReleases)

    #expect(first.name == "Commute")
    #expect(first.position == 0 && second.position == 1)
    #expect(first.rules == .default)
    #expect(try await store.list(id: second.id)?.rules == .newReleases)
    #expect(try await store.lists().map(\.name) == ["Commute", "Gym"])
  }

  @Test func namesMustTrimToOneThroughSixtyCharacters() async throws {
    let (_, store) = try makeStore()
    for bad in ["", "   \n", String(repeating: "x", count: 61)] {
      await #expect(throws: SmartListStoreError.invalidName) { try await store.create(name: bad) }
    }
    let sixty = String(repeating: "x", count: 60)
    #expect(try await store.create(name: sixty).name == sixty)
    let list = try await store.create(name: "A")
    await #expect(throws: SmartListStoreError.invalidName) {
      try await store.rename(id: list.id, to: " ")
    }
  }

  @Test func rulesThatTheDatabaseWouldRefuseAreRefusedFirst() async throws {
    let (_, store) = try makeStore()
    var noStatus = SmartListRules.default
    noStatus.includeUnplayed = false
    noStatus.includeInProgress = false
    var noDownload = SmartListRules.default
    noDownload.includeDownloaded = false
    noDownload.includeNotDownloaded = false
    var badRange = SmartListRules.default
    badRange.durationFilter = true
    badRange.longerThanMinutes = 40
    badRange.shorterThanMinutes = 40

    await #expect(throws: SmartListStoreError.invalidRules(.noEpisodeStatus)) {
      try await store.create(name: "A", rules: noStatus)
    }
    await #expect(throws: SmartListStoreError.invalidRules(.noDownloadStatus)) {
      try await store.create(name: "A", rules: noDownload)
    }
    await #expect(throws: SmartListStoreError.invalidRules(.invalidDurationRange)) {
      try await store.create(name: "A", rules: badRange)
    }
    // The range is not checked while the filter is off.
    badRange.durationFilter = false
    _ = try await store.create(name: "A", rules: badRange)
    #expect(try await store.lists().count == 1)
  }

  @Test func templatesAreValidAndRoundTrip() async throws {
    let (_, store) = try makeStore()
    let templates: [SmartListRules] = [
      .default, .newReleases, .inProgress, .shortEpisodes, .downloaded,
    ]
    for (index, rules) in templates.enumerated() {
      let created = try await store.create(name: "T\(index)", rules: rules)
      #expect(try await store.list(id: created.id)?.rules == rules)
    }
  }

  @Test func updateChangesRulesAndNameButNotPositionOrCreationDate() async throws {
    let (_, store) = try makeStore()
    _ = try await store.create(name: "First")
    let created = try await store.create(name: "Second", now: Date(timeIntervalSince1970: 100))
    var rules = SmartListRules.downloaded
    rules.autoDownload = true
    rules.autoDownloadLimit = .forty

    try await store.update(
      id: created.id, name: " Renamed ", rules: rules, now: Date(timeIntervalSince1970: 200))

    let stored = try #require(try await store.list(id: created.id))
    #expect(stored.name == "Renamed")
    #expect(stored.rules == rules)
    #expect(stored.position == 1)
    #expect(stored.createdAt == Date(timeIntervalSince1970: 100))
    #expect(stored.updatedAt == Date(timeIntervalSince1970: 200))
    await #expect(throws: SmartListStoreError.listNotFound) {
      try await store.updateRules(id: 999, rules: rules)
    }
  }

  // MARK: - Cap and order

  @Test func theFiftyFirstListIsRefusedWithATypedError() async throws {
    let (_, store) = try makeStore()
    for index in 0..<SmartListStore.maximumListCount {
      _ = try await store.create(name: "L\(index)")
    }
    await #expect(throws: SmartListStoreError.listLimitReached) {
      try await store.create(name: "One too many")
    }
    #expect(try await store.lists().count == 50)
    // Deleting one makes room again.
    try await store.delete(id: try #require(try await store.lists().first).id)
    _ = try await store.create(name: "Fits")
    #expect(try await store.lists().count == 50)
  }

  @Test func moveRenumbersDenselyThroughNegativePositions() async throws {
    let (database, store) = try makeStore()
    var ids: [Int64] = []
    for name in ["A", "B", "C", "D"] { ids.append(try await store.create(name: name).id) }

    try await store.move(id: ids[3], toPosition: 0)
    #expect(try await names(store) == ["D", "A", "B", "C"])
    try await store.move(id: ids[3], toPosition: 99)
    #expect(try await names(store) == ["A", "B", "C", "D"])
    try await store.move(id: ids[0], toPosition: 2)
    #expect(try await names(store) == ["B", "C", "A", "D"])
    #expect(try await positions(database) == [0, 1, 2, 3])
    await #expect(throws: SmartListStoreError.listNotFound) {
      try await store.move(id: 999, toPosition: 0)
    }
  }

  @Test func theRenumberParksRowsBelowAnExistingNegativePosition() async throws {
    let (database, store) = try makeStore()
    let a = try await store.create(name: "A").id
    let b = try await store.create(name: "B").id
    try await database.writeAsync { db in
      try db.execute(sql: "UPDATE smartList SET position = -5 WHERE id = ?", arguments: [a])
    }

    try await store.reorder(ids: [b, a])

    #expect(try await names(store) == ["B", "A"])
    #expect(try await positions(database) == [0, 1])
  }

  @Test func reorderRequiresExactlyTheStoredLists() async throws {
    let (_, store) = try makeStore()
    let a = try await store.create(name: "A").id
    let b = try await store.create(name: "B").id
    await #expect(throws: SmartListStoreError.invalidOrder) { try await store.reorder(ids: [a]) }
    await #expect(throws: SmartListStoreError.invalidOrder) {
      try await store.reorder(ids: [a, a])
    }
    await #expect(throws: SmartListStoreError.invalidOrder) {
      try await store.reorder(ids: [a, b, 999])
    }
    try await store.reorder(ids: [b, a])
    #expect(try await names(store) == ["B", "A"])
  }

  @Test func deleteClosesTheGap() async throws {
    let (database, store) = try makeStore()
    let ids = [
      try await store.create(name: "A").id, try await store.create(name: "B").id,
      try await store.create(name: "C").id,
    ]
    try await store.delete(id: ids[1])
    #expect(try await names(store) == ["A", "C"])
    #expect(try await positions(database) == [0, 1])
  }

  // MARK: - Show keys

  @Test func aNativeShowKeyedByFeedURLMatchesAgainAfterUnfollowAndRefollow() async throws {
    let (database, store) = try makeStore()
    let feeds = RSSFeedStore(database: database)
    let url = try #require(URL(string: "https://example.com/feed.xml"))
    let firstID = try await feeds.subscribe(
      feedURL: url, title: "Show", author: nil, synopsis: nil, artworkURL: nil,
      subscribedAt: Date())
    let feedURL = try #require(try await feeds.fetchFeed(feedId: firstID)).feedURL
    let list = try await store.create(
      name: "L",
      shows: [
        SmartListShowSelection(
          ref: .native(feedURL: feedURL), role: .included, titleSnapshot: "Show")
      ])
    #expect(try await matchingNativeShows(database, list.id) == 1)

    try await feeds.unsubscribe(feedId: firstID)
    #expect(try await store.shows(listID: list.id).count == 1)
    #expect(try await matchingNativeShows(database, list.id) == 0)

    let secondID = try await feeds.subscribe(
      feedURL: url, title: "Show", author: nil, synopsis: nil, artworkURL: nil,
      subscribedAt: Date())
    #expect(secondID != firstID)
    #expect(try await matchingNativeShows(database, list.id) == 1)
  }

  @Test func aServerShowSurvivesLogoutAndReloginAndDoesNotMatchAnotherUser() async throws {
    let (database, store) = try makeStore()
    try await insertServerPodcast(database, serverUserID: "user-a", serverItemID: "li_1")
    let list = try await store.create(
      name: "L",
      shows: [
        SmartListShowSelection(
          ref: .server(serverUserID: "user-a", serverItemID: "li_1"), role: .priority,
          titleSnapshot: "Old title")
      ])
    #expect(list.id > 0)
    #expect(try await matchingServerShows(database, list.id) == 1)

    // Logout: the account and its items go; the list's row stays.
    try AccountRemover(database: database).removeAccount(
      accountId: try await database.readAsync { db in
        try Int64.fetchOne(db, sql: "SELECT id FROM account") ?? 0
      })
    #expect(try await store.shows(listID: list.id).count == 1)
    #expect(try await matchingServerShows(database, list.id) == 0)

    // Another user's account with the same item id does not match.
    try await insertServerPodcast(database, serverUserID: "user-b", serverItemID: "li_1")
    #expect(try await matchingServerShows(database, list.id) == 0)
    #expect(try await store.refreshTitleSnapshots() == 0)

    // Re-login as the first user: new account row and client UUID, same server user id.
    try await insertServerPodcast(
      database, serverUserID: "user-a", serverItemID: "li_1", title: "New title")
    #expect(try await matchingServerShows(database, list.id) == 1)
    #expect(try await store.refreshTitleSnapshots() == 1)
    #expect(try await store.shows(listID: list.id).first?.titleSnapshot == "New title")
    #expect(try await store.shows(listID: list.id).first?.role == .priority)
  }

  @Test func theTitleSnapshotNamesAnAbsentShowAndFollowsAPresentOne() async throws {
    let (database, store) = try makeStore()
    let feeds = RSSFeedStore(database: database)
    let url = try #require(URL(string: "https://example.com/other.xml"))
    let list = try await store.create(
      name: "L",
      shows: [
        SmartListShowSelection(
          ref: .native(feedURL: url.absoluteString), role: .included, titleSnapshot: "Chosen as")
      ])

    // Absent: untouched.
    #expect(try await store.refreshTitleSnapshots() == 0)
    #expect(try await store.shows(listID: list.id).first?.titleSnapshot == "Chosen as")

    let feedID = try await feeds.subscribe(
      feedURL: url, title: "Renamed upstream", author: nil, synopsis: nil, artworkURL: nil,
      subscribedAt: Date())
    #expect(try await store.refreshTitleSnapshots() == 1)
    #expect(try await store.shows(listID: list.id).first?.titleSnapshot == "Renamed upstream")
    #expect(try await store.refreshTitleSnapshots() == 0)

    try await feeds.unsubscribe(feedId: feedID)
    #expect(try await store.shows(listID: list.id).first?.titleSnapshot == "Renamed upstream")
  }

  @Test func setShowsReplacesRowsAndKeepsTheLastDuplicate() async throws {
    let (_, store) = try makeStore()
    let list = try await store.create(name: "L")
    let a = SmartListShowRef.native(feedURL: "https://a.example/feed")
    let b = SmartListShowRef.server(serverUserID: "u", serverItemID: "i")

    try await store.setShows(
      listID: list.id,
      shows: [
        SmartListShowSelection(ref: a, role: .included, titleSnapshot: "A"),
        SmartListShowSelection(ref: b, role: .excluded, titleSnapshot: "B"),
        SmartListShowSelection(ref: a, role: .priority, titleSnapshot: "A2"),
      ])
    let rows = try await store.shows(listID: list.id)
    #expect(rows.map(\.showKey) == ["https://a.example/feed", "u|i"])
    #expect(rows.map(\.role) == [.priority, .excluded])
    #expect(rows.map(\.titleSnapshot) == ["A2", "B"])

    try await store.setShows(listID: list.id, shows: [])
    #expect(try await store.shows(listID: list.id).isEmpty)
    await #expect(throws: SmartListStoreError.listNotFound) {
      try await store.setShows(listID: 999, shows: [])
    }
  }

  // MARK: - Helpers

  // MARK: - Atomic save and observation

  @Test func saveWritesFieldsAndShowsTogether() async throws {
    let (_, store) = try makeStore()
    let list = try await store.create(name: "Old")
    let show = SmartListShowSelection(
      ref: .native(feedURL: "https://a.example/feed"), role: .included, titleSnapshot: "A")
    try await store.save(
      id: list.id, name: " New ", rules: .newReleases, shows: [show])
    #expect(try await store.list(id: list.id)?.name == "New")
    #expect(try await store.list(id: list.id)?.rules == .newReleases)
    #expect(try await store.shows(listID: list.id).map(\.showKey) == [show.ref.showKey])
  }

  @Test func aFailureWhileWritingShowsLeavesTheListFieldsUnchanged() async throws {
    let (database, store) = try makeStore()
    let list = try await store.create(name: "Old")
    try await database.writeAsync { db in
      try db.execute(
        sql: """
          CREATE TRIGGER refuseShows BEFORE INSERT ON smartListShow
          BEGIN SELECT RAISE(ABORT, 'refused'); END
          """)
    }
    let show = SmartListShowSelection(
      ref: .native(feedURL: "https://a.example/feed"), role: .included, titleSnapshot: "A")
    await #expect(throws: (any Error).self) {
      try await store.save(id: list.id, name: "New", rules: .newReleases, shows: [show])
    }
    let stored = try #require(try await store.list(id: list.id))
    #expect(stored.name == "Old" && stored.rules == .default)
  }

  @Test func saveRefusesInvalidInputAndMissingListsWithoutWriting() async throws {
    let (_, store) = try makeStore()
    let list = try await store.create(name: "Old")
    await #expect(throws: SmartListStoreError.invalidName) {
      try await store.save(id: list.id, name: " ", rules: .default, shows: [])
    }
    await #expect(throws: SmartListStoreError.listNotFound) {
      try await store.save(id: 999, name: "X", rules: .default, shows: [])
    }
    #expect(try await store.list(id: list.id)?.name == "Old")
  }

  @Test func observeListsEmitsCurrentThenEachCreateRenameAndReorder() async throws {
    let (_, store) = try makeStore()
    var iterator = store.observeLists().makeAsyncIterator()
    #expect(try #require(await iterator.next()).isEmpty)
    let a = try await store.create(name: "A")
    #expect(try #require(await iterator.next()).map(\.name) == ["A"])
    let b = try await store.create(name: "B")
    #expect(try #require(await iterator.next()).map(\.name) == ["A", "B"])
    try await store.rename(id: a.id, to: "A2")
    #expect(try #require(await iterator.next()).map(\.name) == ["A2", "B"])
    try await store.reorder(ids: [b.id, a.id])
    #expect(try #require(await iterator.next()).map(\.name) == ["B", "A2"])
  }

  private func makeStore() throws -> (AppDatabase, SmartListStore) {
    let database = try AppDatabase.inMemory()
    return (database, SmartListStore(database: database))
  }

  private func names(_ store: SmartListStore) async throws -> [String] {
    try await store.lists().map(\.name)
  }

  private func positions(_ database: AppDatabase) async throws -> [Int] {
    try await database.readAsync { db in
      try Int.fetchAll(db, sql: "SELECT position FROM smartList ORDER BY position")
    }
  }

  private func matchingNativeShows(_ database: AppDatabase, _ listID: Int64) async throws -> Int {
    try await database.readAsync { db in
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM smartListShow show
          JOIN rssFeed feed ON feed.feedURL = show.showKey
          WHERE show.listId = ? AND show.source = 'native'
          """, arguments: [listID]) ?? -1
    }
  }

  private func matchingServerShows(_ database: AppDatabase, _ listID: Int64) async throws -> Int {
    try await database.readAsync { db in
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM smartListShow show
          JOIN item ON show.showKey = (SELECT serverUserId FROM account WHERE id = item.accountId)
            || '|' || item.serverItemId
          WHERE show.listId = ? AND show.source = 'server'
          """, arguments: [listID]) ?? -1
    }
  }

  private func insertServerPodcast(
    _ database: AppDatabase, serverUserID: String, serverItemID: String, title: String = "Show"
  ) async throws {
    try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
        serverUserId: serverUserID, serverVersion: "2.10.0")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "lib", mediaType: "podcast", name: "Library")
      try library.insert(db)
      var item = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: serverItemID,
        mediaKind: "podcast", title: title, sortTitle: title.lowercased())
      try item.insert(db)
    }
  }
}

import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import AppModel

@MainActor
@Suite("SmartListEditorModel")
struct SmartListEditorModelTests {
  private static let fingerprint = String(repeating: "ab", count: 32)
  private static let feedA = "https://a.example/feed"
  private static let feedB = "https://b.example/feed"

  private func editor(
    _ fixture: SmartListFixture, mode: SmartListEditorModel.Mode = .create,
    template: SmartListTemplate = .blank
  ) -> SmartListEditorModel {
    SmartListEditorModel(
      services: fixture.services, mode: mode, template: template, debounce: .milliseconds(1))
  }

  // MARK: Validation

  @Test("a name is required, trimmed, and at most sixty characters")
  func nameValidation() async throws {
    let fixture = try SmartListFixture()
    let model = editor(fixture)
    #expect(model.nameValidation == .empty)
    #expect(model.canSave == false)

    model.name = "   \n "
    #expect(model.nameValidation == .empty)

    model.name = String(repeating: "x", count: SmartListRules.maximumNameLength + 1)
    #expect(model.nameValidation == .tooLong)
    #expect(model.canSave == false)

    model.name = "  Commute  "
    #expect(model.nameValidation == .valid)
    #expect(model.canSave)
  }

  @Test("rules are validated by the store's own rule check")
  func rulesValidation() async throws {
    let fixture = try SmartListFixture()
    let model = editor(fixture)
    model.name = "L"

    model.rules.includeUnplayed = false
    model.rules.includeInProgress = false
    model.rules.includePlayed = false
    #expect(model.rulesError == .noEpisodeStatus)
    #expect(model.canSave == false)
    #expect(await model.save() == nil)
    #expect(model.saveError == .invalidRules(.noEpisodeStatus))
    model.rules.includePlayed = true

    model.rules.includeDownloaded = false
    model.rules.includeNotDownloaded = false
    #expect(model.rulesError == .noDownloadStatus)
    model.rules.includeDownloaded = true

    model.rules.durationFilter = true
    model.rules.longerThanMinutes = 40
    model.rules.shorterThanMinutes = 20
    #expect(model.rulesError == .invalidDurationRange)
    model.rules.longerThanMinutes = 20
    model.rules.shorterThanMinutes = 40
    #expect(model.rulesError == nil)
    #expect(model.canSave)
  }

  @Test("auto-download is off at first, turns on at ten, and takes the offered limits")
  func autoDownloadDraft() async throws {
    let fixture = try SmartListFixture()
    let model = editor(fixture)
    #expect(model.autoDownload == false)
    model.autoDownload = true
    #expect(model.autoDownloadLimit == .ten)
    model.autoDownloadLimit = .forty
    #expect(model.rules.autoDownload)
    #expect(model.rules.autoDownloadLimit == .forty)
    model.name = "L"

    let list = try #require(await model.save())
    #expect(list.rules.autoDownload)
    #expect(list.rules.autoDownloadLimit == .forty)
  }

  @Test("auto-download needs both download states: choosing one turns it off and keeps it off")
  func autoDownloadNeedsBothDownloadStates() async throws {
    let fixture = try SmartListFixture()
    let model = editor(fixture)
    #expect(model.canAutoDownload)
    model.autoDownload = true

    model.rules.includeNotDownloaded = false
    #expect(model.canAutoDownload == false)
    #expect(model.autoDownload == false)
    model.autoDownload = true
    #expect(model.rules.autoDownload == false)

    model.rules.includeNotDownloaded = true
    #expect(model.canAutoDownload)
    model.autoDownload = true
    #expect(model.rules.autoDownload)
    #expect(editor(fixture, template: .downloaded).canAutoDownload == false)
  }

  @Test("templates start the draft")
  func templates() async throws {
    let fixture = try SmartListFixture()
    let short = editor(fixture, template: .shortEpisodes)
    #expect(short.name == "Short episodes")
    #expect(short.rules == .shortEpisodes)
    let week = editor(fixture, template: .newEpisodesThisWeek)
    #expect(week.rules.releaseWindow == .week)
    #expect(editor(fixture, template: .downloaded).rules.includeNotDownloaded == false)
  }

  // MARK: Live match count

  @Test("the match count follows the draft rules and chosen shows")
  func liveMatchCount() async throws {
    let fixture = try SmartListFixture(
      catalog: [
        SmartListCatalogShow(ref: .native(feedURL: Self.feedA), title: "A"),
        SmartListCatalogShow(ref: .native(feedURL: Self.feedB), title: "B"),
      ])
    let a = try await fixture.feed(Self.feedA, title: "A")
    let b = try await fixture.feed(Self.feedB, title: "B")
    try await fixture.episode(feed: a, "a1", ageSeconds: 60, duration: 600)
    try await fixture.episode(feed: a, "a2", ageSeconds: 120, duration: 3_600)
    try await fixture.episode(feed: b, "b1", ageSeconds: 180, duration: 600)
    let model = editor(fixture)
    #expect(await waitUntil("all shows") { model.matchCount == 3 })

    model.rules.durationFilter = true
    model.rules.longerThanMinutes = 0
    model.rules.shorterThanMinutes = 20
    #expect(await waitUntil("short only") { model.matchCount == 2 })

    model.rules.durationFilter = false
    model.rules.showScope = .only
    model.setRole(.included, for: .native(feedURL: Self.feedA))
    #expect(await waitUntil("only A") { model.matchCount == 2 })

    model.rules.showScope = .allExcept
    model.setRole(.excluded, for: .native(feedURL: Self.feedA))
    #expect(await waitUntil("all except A") { model.matchCount == 1 })

    model.rules.includeUnplayed = false
    model.rules.includeInProgress = false
    model.rules.includePlayed = false
    #expect(model.matchCount == nil)
  }

  @Test("the count of an existing list leaves its hidden episodes out")
  func countHonoursHiddenEpisodes() async throws {
    let fixture = try SmartListFixture()
    let feed = try await fixture.feed(Self.feedA)
    try await fixture.episode(feed: feed, "a1", ageSeconds: 60)
    try await fixture.episode(feed: feed, "a2", ageSeconds: 120)
    let list = try await fixture.services.store.create(name: "L")
    try await fixture.services.hiddenEpisodes.hide(
      listID: list.id, itemID: fixture.nativeItemID(feed), episodeID: "a1")
    let model = editor(fixture, mode: .edit(listID: list.id))
    await model.load()
    #expect(await waitUntil("one visible") { model.matchCount == 1 })
  }

  // MARK: Save

  @Test("saving a new list writes name, rules and shows, then expands its shows")
  func saveCreates() async throws {
    let fixture = try SmartListFixture(
      catalog: [SmartListCatalogShow(ref: .native(feedURL: Self.feedA), title: "A")])
    try await fixture.signIn()
    try await fixture.feed(Self.feedA, title: "A")
    let model = editor(fixture)
    #expect(await waitUntil("account known") { model.sources?.accountID != nil })
    model.name = "  Commute "
    model.rules.showScope = .only
    model.rules.sortOrder = .oldest
    model.setRole(.priority, for: .native(feedURL: Self.feedA))
    var saved: [Int64] = []
    model.onSaved = { saved.append($0.id) }

    let list = try #require(await model.save())
    #expect(list.name == "Commute")
    #expect(list.rules.sortOrder == .oldest)
    #expect(model.savedList == list)
    #expect(saved == [list.id])
    let shows = try await fixture.services.store.shows(listID: list.id)
    #expect(shows.map(\.showKey) == [Self.feedA])
    #expect(shows.map(\.role) == [.priority])
    #expect(shows.map(\.titleSnapshot) == ["A"])
    await model.expansionTask?.value
    #expect(fixture.expansions.listIDs == [list.id])
  }

  @Test("saving signed out writes the list and starts no expansion")
  func saveSignedOutDoesNotExpand() async throws {
    let fixture = try SmartListFixture()
    let model = editor(fixture)
    #expect(await waitUntil("sources") { model.sources != nil })
    model.name = "L"
    let list = try #require(await model.save())
    #expect(list.name == "L")
    #expect(model.expansionTask == nil)
    #expect(fixture.expansions.listIDs.isEmpty)
  }

  @Test("a second save edits the list the first one made")
  func secondSaveEdits() async throws {
    let fixture = try SmartListFixture()
    let model = editor(fixture)
    model.name = "First"
    let created = try #require(await model.save())
    model.name = "Second"
    let edited = try #require(await model.save())
    #expect(edited.id == created.id)
    #expect(try await fixture.services.store.lists().map(\.name) == ["Second"])
  }

  @Test("the fifty-first list is refused as a model error")
  func saveHitsCap() async throws {
    let fixture = try SmartListFixture()
    let store = fixture.services.store
    for index in 0..<SmartListStore.maximumListCount { try await store.create(name: "L\(index)") }
    let model = editor(fixture)
    model.name = "Too many"
    #expect(await model.save() == nil)
    #expect(model.saveError == .listLimitReached)
    #expect(model.isSaving == false)
  }

  @Test("editing loads the list, replaces its rules and shows, and leaves hidden episodes alone")
  func editRoundTrip() async throws {
    let fixture = try SmartListFixture(
      catalog: [
        SmartListCatalogShow(ref: .native(feedURL: Self.feedA), title: "A"),
        SmartListCatalogShow(ref: .native(feedURL: Self.feedB), title: "B"),
      ])
    let feed = try await fixture.feed(Self.feedA, title: "A")
    try await fixture.feed(Self.feedB, title: "B")
    let store = fixture.services.store
    let list = try await store.create(
      name: "Old", rules: SmartListRules(showScope: .only),
      shows: [
        SmartListShowSelection(
          ref: .native(feedURL: Self.feedA), role: .included, titleSnapshot: "A")
      ])
    try await fixture.services.hiddenEpisodes.hide(
      listID: list.id, itemID: fixture.nativeItemID(feed), episodeID: "a1")

    let model = editor(fixture, mode: .edit(listID: list.id))
    #expect(model.isLoading)
    await model.load()
    #expect(model.isLoading == false)
    #expect(model.name == "Old")
    #expect(model.rules.showScope == .only)
    #expect(model.role(for: .native(feedURL: Self.feedA)) == .included)

    model.name = "New"
    model.rules.showScope = .allExcept
    model.setRole(nil, for: .native(feedURL: Self.feedA))
    model.setRole(.excluded, for: .native(feedURL: Self.feedB))
    let saved = try #require(await model.save())

    #expect(saved.id == list.id)
    #expect(saved.name == "New")
    let shows = try await store.shows(listID: list.id)
    #expect(shows.map(\.showKey) == [Self.feedB])
    #expect(shows.map(\.role) == [.excluded])
    #expect(try await store.lists().count == 1)
    let hidden = try await fixture.services.hiddenEpisodes.hiddenEpisodes(listID: list.id)
    #expect(hidden.count == 1)
  }

  @Test("editing a list that is gone reports it")
  func editMissing() async throws {
    let fixture = try SmartListFixture()
    let model = editor(fixture, mode: .edit(listID: 999))
    await model.load()
    #expect(model.loadError == .listNotFound)
    #expect(model.canSave == false)
  }

  @Test("switching scope drops the roles the scope cannot use, keeping priority")
  func scopeFiltersRoles() async throws {
    let fixture = try SmartListFixture(
      catalog: [
        SmartListCatalogShow(ref: .native(feedURL: Self.feedA), title: "A"),
        SmartListCatalogShow(ref: .native(feedURL: Self.feedB), title: "B"),
      ])
    let model = editor(fixture)
    #expect(await waitUntil("catalogue") { model.pickerShows.count == 2 })
    model.setRole(.included, for: .native(feedURL: Self.feedA))
    model.setRole(.priority, for: .native(feedURL: Self.feedB))

    model.rules.showScope = .only
    #expect(model.selections.map(\.role) == [.included, .priority])
    model.rules.showScope = .allExcept
    #expect(model.selections.map(\.role) == [.priority])
    model.rules.showScope = .all
    #expect(model.selections.map(\.showKeyForTest) == [Self.feedB])
  }

  // MARK: Show picker

  @Test("the picker lists both sources and a twin once, as the native show")
  func pickerCollapsesTwins() async throws {
    let serverTwin = SmartListShowRef.server(serverUserID: "user-1", serverItemID: "s-twin")
    let serverOnly = SmartListShowRef.server(serverUserID: "user-1", serverItemID: "s-only")
    let fixture = try SmartListFixture(
      catalog: [
        SmartListCatalogShow(
          ref: .native(feedURL: Self.feedA), title: "A", fingerprint: Self.fingerprint),
        SmartListCatalogShow(ref: serverTwin, title: "A (server)", fingerprint: Self.fingerprint),
        SmartListCatalogShow(ref: serverOnly, title: "Z"),
      ])
    let account = try await fixture.signIn()
    try await fixture.feed(Self.feedA, title: "A", fingerprint: Self.fingerprint)
    try await fixture.serverShow(account, "s-twin", fingerprint: Self.fingerprint)
    try await fixture.serverShow(account, "s-only")
    let model = editor(fixture)

    #expect(await waitUntil("picker") { model.pickerShows.map(\.title) == ["A", "Z"] })
    #expect(model.pickerShows.map(\.source) == [.native, .server])

    model.setRole(.included, for: .native(feedURL: Self.feedA))
    model.rules.showScope = .only
    #expect(Set(model.selections.map(\.ref)) == [.native(feedURL: Self.feedA), serverTwin])
    #expect(model.selections.allSatisfy { $0.role == .included })
  }

  @Test("the server half of the picker is hidden while signed out, native while native is off")
  func pickerFollowsSources() async throws {
    let server = SmartListShowRef.server(serverUserID: "user-1", serverItemID: "s1")
    let fixture = try SmartListFixture(
      nativeEnabled: false,
      catalog: [
        SmartListCatalogShow(ref: .native(feedURL: Self.feedA), title: "A"),
        SmartListCatalogShow(ref: server, title: "S"),
      ])
    let model = editor(fixture)
    #expect(await waitUntil("nothing available") { model.sources != nil })
    #expect(model.pickerShows.isEmpty)

    await fixture.preference.setEnabled(true)
    #expect(await waitUntil("native shows") { model.pickerShows.map(\.title) == ["A"] })

    try await fixture.signIn()
    #expect(await waitUntil("both") { model.pickerShows.map(\.title) == ["A", "S"] })
  }

  @Test("a stored show that is gone reads Not followed or Not available on this server")
  func pickerStoredAbsentShows() async throws {
    let gone = SmartListShowRef.native(feedURL: "https://gone.example/feed")
    let away = SmartListShowRef.server(serverUserID: "user-1", serverItemID: "s-away")
    let fixture = try SmartListFixture(
      catalog: [SmartListCatalogShow(ref: .native(feedURL: Self.feedA), title: "A")])
    try await fixture.signIn()
    let list = try await fixture.services.store.create(
      name: "L", rules: SmartListRules(showScope: .only),
      shows: [
        SmartListShowSelection(ref: gone, role: .included, titleSnapshot: "Gone Show"),
        SmartListShowSelection(ref: away, role: .priority, titleSnapshot: "Away Show"),
      ])
    let model = editor(fixture, mode: .edit(listID: list.id))
    await model.load()

    #expect(await waitUntil("picker") { model.pickerShows.count == 3 })
    let byTitle = Dictionary(uniqueKeysWithValues: model.pickerShows.map { ($0.title, $0) })
    #expect(byTitle["A"]?.availability == .available)
    #expect(byTitle["Gone Show"]?.availability == .notFollowed)
    #expect(byTitle["Gone Show"]?.role == .included)
    #expect(byTitle["Away Show"]?.availability == .notOnServer)
    #expect(byTitle["Away Show"]?.role == .priority)

    // Saving keeps them: they come back when the show is followed again, or the server returns.
    _ = try #require(await model.save())
    let kept = try await fixture.services.store.shows(listID: list.id)
    #expect(Set(kept.map(\.showKey)) == [gone.showKey, away.showKey])
  }

  // MARK: Updating shows

  @Test("Updating shows shows while a named server show has no complete episode list")
  func updatingShowsFlag() async throws {
    let fixture = try SmartListFixture()
    let account = try await fixture.signIn()
    let item = try await fixture.serverShow(account, "s1")
    let list = try await fixture.services.store.create(name: "L")
    let model = editor(fixture, mode: .edit(listID: list.id))
    await model.load()
    #expect(await waitUntil("updating") { model.isUpdatingShows })

    try await fixture.database.writeAsync { db in
      try db.execute(
        sql: """
          INSERT INTO podcastRefreshState (itemId, consecutiveFailures, lastCompleteEpisodeListAt)
          VALUES (?, 0, ?)
          """,
        arguments: [item, SmartListFixture.epoch])
    }
    #expect(await waitUntil("settled") { model.isUpdatingShows == false })
  }
}

extension SmartListShowSelection {
  fileprivate var showKeyForTest: String { ref.showKey }
}

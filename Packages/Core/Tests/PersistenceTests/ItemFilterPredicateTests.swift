import Foundation
import GRDB
import TestSupport
import Testing

@testable import Persistence

/// The status predicates shared by Search and Home, in one enum beside `ItemCategoryPredicate`.
/// Every assertion runs the real SQL against an in-memory database, not a string match.
///
/// The three download scopes are tested separately: item-only (a Search result row or item
/// badge), episode-only (an episode row), and every row under a library entry (Home's Downloaded
/// shelf, so a podcast show leads to its completed episode downloads).
@Suite struct ItemFilterPredicateTests {

  // MARK: - Item-scoped downloaded

  @Test("item-scoped downloaded needs at least one live row and every live row completed")
  func itemScopedDownloadedPinsTheLiveAllCompleteRule() async throws {
    let fixture = try await Fixture()

    let completed = try await fixture.book("one-completed")
    try await fixture.download(itemId: completed, state: .completed)

    let downloading = try await fixture.book("downloading")
    try await fixture.download(itemId: downloading, state: .downloading)

    let mixed = try await fixture.book("completed-and-downloading")
    try await fixture.download(itemId: mixed, state: .completed)
    try await fixture.download(itemId: mixed, state: .downloading)

    let deletingOnly = try await fixture.book("only-deleting")
    try await fixture.download(itemId: deletingOnly, state: .deleting)

    _ = try await fixture.book("no-rows")

    #expect(
      try fixture.items(matching: ItemFilterPredicate.itemDownloadedOnly(true)) == ["one-completed"])
  }

  @Test("an episode-level download row never makes its item count as item-downloaded")
  func itemScopedDownloadedIgnoresEpisodeRows() async throws {
    let fixture = try await Fixture()

    let show = try await fixture.show("show")
    let episode = try await fixture.episode(itemId: show, serverEpisodeId: "ep1")
    try await fixture.download(itemId: show, podcastEpisodeId: episode, state: .completed)

    #expect(try fixture.items(matching: ItemFilterPredicate.itemDownloadedOnly(true)).isEmpty)
  }

  // MARK: - Episode-scoped downloaded

  @Test("episode-scoped downloaded applies the same live/all-complete rule to episode rows")
  func episodeScopedDownloadedPinsTheSameRule() async throws {
    let fixture = try await Fixture()
    let show = try await fixture.show("show")

    let completed = try await fixture.episode(itemId: show, serverEpisodeId: "one-completed")
    try await fixture.download(itemId: show, podcastEpisodeId: completed, state: .completed)

    let downloading = try await fixture.episode(itemId: show, serverEpisodeId: "downloading")
    try await fixture.download(itemId: show, podcastEpisodeId: downloading, state: .downloading)

    let mixed = try await fixture.episode(itemId: show, serverEpisodeId: "completed-and-downloading")
    try await fixture.download(itemId: show, podcastEpisodeId: mixed, state: .completed)
    try await fixture.download(itemId: show, podcastEpisodeId: mixed, state: .downloading)

    let deletingOnly = try await fixture.episode(itemId: show, serverEpisodeId: "only-deleting")
    try await fixture.download(itemId: show, podcastEpisodeId: deletingOnly, state: .deleting)

    _ = try await fixture.episode(itemId: show, serverEpisodeId: "no-rows")

    #expect(
      try fixture.episodes(matching: ItemFilterPredicate.episodeDownloadedOnly(true))
        == ["one-completed"])
  }

  @Test("an item-level download row never makes an episode of that item count as downloaded")
  func episodeScopedDownloadedIgnoresItemRows() async throws {
    let fixture = try await Fixture()
    let show = try await fixture.show("show")
    _ = try await fixture.episode(itemId: show, serverEpisodeId: "ep1")
    try await fixture.download(itemId: show, state: .completed)

    #expect(try fixture.episodes(matching: ItemFilterPredicate.episodeDownloadedOnly(true)).isEmpty)
  }

  // MARK: - Library-entry downloaded (Home's show-navigation scope)

  @Test("library-entry downloaded spans every row under the item, item-level and episode-level")
  func libraryEntryDownloadedSpansEveryRowUnderTheItem() async throws {
    let fixture = try await Fixture()

    // A podcast show whose only downloads are episode-scoped still counts, so the show can act as
    // navigation into its completed episode downloads.
    let completeShow = try await fixture.show("complete-show")
    let completeEpisode = try await fixture.episode(itemId: completeShow, serverEpisodeId: "cs-ep1")
    try await fixture.download(itemId: completeShow, podcastEpisodeId: completeEpisode, state: .completed)

    // One completed episode plus one still transferring is not a complete entry.
    let partialShow = try await fixture.show("partial-show")
    let doneEpisode = try await fixture.episode(itemId: partialShow, serverEpisodeId: "ps-ep1")
    let busyEpisode = try await fixture.episode(itemId: partialShow, serverEpisodeId: "ps-ep2")
    try await fixture.download(itemId: partialShow, podcastEpisodeId: doneEpisode, state: .completed)
    try await fixture.download(itemId: partialShow, podcastEpisodeId: busyEpisode, state: .downloading)

    // Item-level rows are in the same scope as episode-level ones.
    let completeBook = try await fixture.book("complete-book")
    try await fixture.download(itemId: completeBook, state: .completed)

    let mixedScopes = try await fixture.show("mixed-scopes")
    let mixedEpisode = try await fixture.episode(itemId: mixedScopes, serverEpisodeId: "ms-ep1")
    try await fixture.download(itemId: mixedScopes, state: .completed)
    try await fixture.download(itemId: mixedScopes, podcastEpisodeId: mixedEpisode, state: .downloading)

    let deletingOnly = try await fixture.book("only-deleting")
    try await fixture.download(itemId: deletingOnly, state: .deleting)

    _ = try await fixture.book("no-rows")

    #expect(
      try fixture.items(matching: ItemFilterPredicate.libraryEntryDownloadedOnly(true))
        == ["complete-book", "complete-show"])
  }

  // MARK: - Playback

  @Test("the three engaged states partition the same rows: never started, started, finished")
  func playbackStatesPartitionEveryItem() async throws {
    let fixture = try await Fixture()

    _ = try await fixture.book("no-progress")

    let started = try await fixture.book("started")
    try await fixture.progress(itemId: started, isFinished: false)

    let finished = try await fixture.book("finished")
    try await fixture.progress(itemId: finished, isFinished: true)

    #expect(
      try fixture.items(matching: ItemFilterPredicate.itemPlayback(.unfinished)) == ["no-progress"])
    #expect(
      try fixture.items(matching: ItemFilterPredicate.itemPlayback(.inProgress)) == ["started"])
    #expect(try fixture.items(matching: ItemFilterPredicate.itemPlayback(.finished)) == ["finished"])
  }

  /// Pins the property the shared "has any progress" subquery guarantees, over all states rather
  /// than one fixture. An edit making `inProgress` merely "not finished" would fail only here.
  @Test("no item matches two engaged playback states")
  func engagedPlaybackStatesNeverOverlap() async throws {
    let fixture = try await Fixture()

    _ = try await fixture.book("no-progress")
    let zeroPosition = try await fixture.book("zero-position")
    try await fixture.progress(itemId: zeroPosition, currentTime: 0, isFinished: false)
    let started = try await fixture.book("started")
    try await fixture.progress(itemId: started, isFinished: false)
    let ebook = try await fixture.book("ebook-only")
    try await fixture.progress(itemId: ebook, currentTime: 0, ebookProgress: 0.4, isFinished: false)
    let finished = try await fixture.book("finished")
    try await fixture.progress(itemId: finished, isFinished: true)

    let states: [PlaybackFilter] = [.unfinished, .inProgress, .finished]
    var seen: [String: PlaybackFilter] = [:]
    for state in states {
      for id in try fixture.items(matching: ItemFilterPredicate.itemPlayback(state)) {
        #expect(seen[id] == nil, "\(id) matched both \(seen[id]!) and \(state)")
        seen[id] = state
      }
    }
    #expect(seen.count == 5, "every item matched exactly one engaged state")
  }

  @Test("a zero position is never started, and an ebook position alone is in progress")
  func positionKindsClassifyCorrectly() async throws {
    let fixture = try await Fixture()

    let zeroPosition = try await fixture.book("zero-position")
    try await fixture.progress(itemId: zeroPosition, currentTime: 0, isFinished: false)

    let ebook = try await fixture.book("ebook-only")
    try await fixture.progress(itemId: ebook, currentTime: 0, ebookProgress: 0.4, isFinished: false)

    #expect(
      try fixture.items(matching: ItemFilterPredicate.itemPlayback(.unfinished)) == ["zero-position"]
    )
    #expect(
      try fixture.items(matching: ItemFilterPredicate.itemPlayback(.inProgress)) == ["ebook-only"])
  }

  /// A show cannot answer an item-scoped playback question, so it answers none of them. Podcast
  /// progress is episode-keyed; the item-level row written here is the representable-but-unwritten
  /// case, and it must not readmit the show.
  @Test("a podcast show is excluded from every engaged playback state, item-level row or not")
  func podcastShowsAreExcludedFromEveryEngagedState() async throws {
    let fixture = try await Fixture()

    _ = try await fixture.show("untouched-show")
    let finishedShow = try await fixture.show("finished-show")
    try await fixture.progress(itemId: finishedShow, isFinished: true)
    let book = try await fixture.book("book")
    try await fixture.progress(itemId: book, isFinished: true)

    for state in [PlaybackFilter.unfinished, .inProgress, .finished] {
      let matched = try fixture.items(matching: ItemFilterPredicate.itemPlayback(state))
      #expect(matched.contains("untouched-show") == false)
      #expect(matched.contains("finished-show") == false)
    }
    #expect(try fixture.items(matching: ItemFilterPredicate.itemPlayback(.finished)) == ["book"])
  }

  @Test("a finished item does not make its episodes finished, and vice versa")
  func episodeScopedProgressIsIndependentOfItemScoped() async throws {
    let fixture = try await Fixture()

    let finishedShow = try await fixture.show("finished-show")
    let unfinishedEpisode = try await fixture.episode(itemId: finishedShow, serverEpisodeId: "unfinished-ep")
    try await fixture.progress(itemId: finishedShow, isFinished: true)

    let unfinishedShow = try await fixture.show("unfinished-show")
    let finishedEpisode = try await fixture.episode(itemId: unfinishedShow, serverEpisodeId: "finished-ep")
    try await fixture.progress(itemId: unfinishedShow, podcastEpisodeId: finishedEpisode, isFinished: true)

    // The finished show's own episode is untouched, and the unfinished show's finished episode is
    // not made unfinished by its parent. Item scope excludes shows entirely
    // (`podcastShowsAreExcludedFromEveryEngagedState`), so this independence can only be asserted
    // at episode scope.
    #expect(
      try fixture.episodes(matching: ItemFilterPredicate.episodePlayback(.unfinished))
        == ["unfinished-ep"])
    #expect(
      try fixture.episodes(matching: ItemFilterPredicate.episodePlayback(.finished))
        == ["finished-ep"])
    #expect(try fixture.items(matching: ItemFilterPredicate.itemPlayback(.finished)).isEmpty)
    _ = unfinishedEpisode
  }

  @Test("episode scope has its own in-progress state, independent of the parent item")
  func episodeScopedInProgressIsIndependent() async throws {
    let fixture = try await Fixture()

    let show = try await fixture.show("show")
    let startedEpisode = try await fixture.episode(itemId: show, serverEpisodeId: "started-ep")
    try await fixture.progress(itemId: show, podcastEpisodeId: startedEpisode, isFinished: false)
    _ = try await fixture.episode(itemId: show, serverEpisodeId: "untouched-ep")
    let finishedEpisode = try await fixture.episode(itemId: show, serverEpisodeId: "finished-ep")
    try await fixture.progress(itemId: show, podcastEpisodeId: finishedEpisode, isFinished: true)

    #expect(
      try fixture.episodes(matching: ItemFilterPredicate.episodePlayback(.inProgress))
        == ["started-ep"])
    #expect(
      try fixture.episodes(matching: ItemFilterPredicate.episodePlayback(.unfinished))
        == ["untouched-ep"])
    #expect(
      try fixture.episodes(matching: ItemFilterPredicate.episodePlayback(.finished))
        == ["finished-ep"])
  }

  // MARK: - The no-op case

  @Test("every inactive dimension emits the literal no-op predicate, byte for byte")
  func inactiveDimensionsEmitTheNoOpPredicate() {
    #expect(ItemFilterPredicate.itemDownloadedOnly(false) == "1")
    #expect(ItemFilterPredicate.episodeDownloadedOnly(false) == "1")
    #expect(ItemFilterPredicate.libraryEntryDownloadedOnly(false) == "1")
    #expect(ItemFilterPredicate.itemPlayback(.any) == "1")
    #expect(ItemFilterPredicate.episodePlayback(.any) == "1")
  }

  // MARK: - Fixture

  /// Owns one in-memory database plus the account/library rows every predicate query needs, and
  /// runs a predicate as the sole `WHERE` clause of a real query.
  private struct Fixture {
    let database: AppDatabase
    let accountId: Int64
    let libraryRowId: Int64

    init() async throws {
      database = try AppDatabase.inMemory()
      (accountId, libraryRowId) = try await database.writeAsync { db in
        var account = AccountRecord(
          clientUUID: UUID().uuidString, serverBaseURL: "https://example.com",
          serverUserId: "user-1", serverVersion: "2.35.1")
        try account.insert(db)
        var library = LibraryRecord(
          accountId: account.id!, serverLibraryId: "lib1", mediaType: "book", name: "Library")
        try library.insert(db)
        return (account.id!, library.id!)
      }
    }

    func book(_ serverItemId: String) async throws -> Int64 {
      try await insertItem(serverItemId, mediaKind: "book")
    }

    func show(_ serverItemId: String) async throws -> Int64 {
      try await insertItem(serverItemId, mediaKind: "podcast")
    }

    private func insertItem(_ serverItemId: String, mediaKind: String) async throws -> Int64 {
      try await database.writeAsync { db in
        var item = PersistenceFixtures.item(
          accountId: accountId, libraryId: libraryRowId, serverItemId: serverItemId,
          mediaKind: mediaKind, title: serverItemId, sortTitle: serverItemId)
        try item.insert(db)
        return item.id!
      }
    }

    func episode(itemId: Int64, serverEpisodeId: String) async throws -> Int64 {
      try await database.writeAsync { db in
        var episode = PodcastEpisodeRecord(
          accountId: accountId, itemId: itemId, serverEpisodeId: serverEpisodeId,
          title: serverEpisodeId, lastSeenGeneration: 1)
        try episode.insert(db)
        return episode.id!
      }
    }

    func download(itemId: Int64, podcastEpisodeId: Int64? = nil, state: DownloadState) async throws {
      try await database.writeAsync { db in
        var download = DownloadRecord(
          accountId: accountId, itemId: itemId, podcastEpisodeId: podcastEpisodeId,
          serverFileIno: UUID().uuidString, orderIndex: 0,
          destinationRelativePath: "downloads/\(UUID().uuidString)", expectedBytes: 100,
          expectedMimeType: "audio/mp4", fileDurationSeconds: 60,
          receivedBytes: state == .completed ? 100 : 0, state: state)
        try download.insert(db)
      }
    }

    /// `currentTime` defaults to a real position, because that is what a progress row ordinarily
    /// carries. Pass `currentTime: 0` for the row a never-started item can still have (a reset, or
    /// a server row pulled before anything was played).
    func progress(
      itemId: Int64, podcastEpisodeId: Int64? = nil, currentTime: Double? = nil,
      ebookProgress: Double? = nil, isFinished: Bool
    ) async throws {
      try await database.writeAsync { db in
        var progress = MediaProgressRecord(
          accountId: accountId, itemId: itemId, podcastEpisodeId: podcastEpisodeId,
          currentTime: currentTime ?? (isFinished ? 100 : 30), isFinished: isFinished,
          localSequence: 1, origin: .local, originKey: "client-uuid", ebookProgress: ebookProgress)
        try progress.insert(db)
      }
    }

    func items(matching predicate: String) throws -> [String] {
      try database.read { db in
        try String.fetchAll(
          db,
          sql: """
            SELECT item.serverItemId FROM item
            WHERE (\(predicate))
            ORDER BY item.serverItemId
            """)
      }
    }

    func episodes(matching predicate: String) throws -> [String] {
      try database.read { db in
        try String.fetchAll(
          db,
          sql: """
            SELECT episode.serverEpisodeId FROM podcastEpisode AS episode
            WHERE (\(predicate))
            ORDER BY episode.serverEpisodeId
            """)
      }
    }
  }
}

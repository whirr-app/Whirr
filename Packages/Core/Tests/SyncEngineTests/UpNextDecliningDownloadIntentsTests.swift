import Foundation
import GRDB
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

/// A hand removal declines the Up Next entries it names before the purge; a hand download clears
/// the decline.
@Suite struct UpNextDecliningDownloadIntentsTests {

  @Test func everyHandRemovalDeclinesBeforeItPurges() async throws {
    let (intents, wrapped, declines) = make()
    declines.purgeCountAtDecline = { wrapped.calls.count }
    try await intents.purgeEpisodeDownload(itemID: "rss:1", episodeID: "e1", source: .podcastEpisodeRemoval)
    try await intents.purgeEpisodeDownload(itemID: "show", episodeID: "s1", source: .contextMenu)
    try await intents.purgeItemDownload(itemID: "book", source: .itemDetail)
    try await intents.purgeItemDownload(itemID: "show", source: .storage)
    try await intents.purgeAllDownloads(source: .storage)
    try await intents.purgeTombstonedEpisodeDownloads(source: .storage)

    #expect(
      declines.declines == [
        .init("rss:1", "e1"), .init("show", "s1"), .init("book", nil), .init("show", nil),
        .init(nil, nil), .tombstoned,
      ])
    // Each decline saw only the purges before it, so it was written ahead of its own purge.
    #expect(declines.purgesSeenAtDecline == [0, 1, 2, 3, 4, 5])
    #expect(wrapped.calls.count == 6)
  }

  @Test func automaticAndReleasePurgesNeverDecline() async throws {
    let (intents, wrapped, declines) = make()
    let sources: [DownloadPurgeSource] = [
      .storageCeiling, .finishedDownloadAutoDelete, .pinnedListRelease, .smartListRelease,
      .autoDownloadReaper, .readerEbook, .accountRemoval,
    ]
    for source in sources {
      try await intents.purgeEpisodeDownload(itemID: "rss:1", episodeID: "e1", source: source)
      try await intents.purgeItemDownload(itemID: "book", source: source)
      try await intents.purgeAllDownloads(source: source)
      try await intents.purgeTombstonedEpisodeDownloads(source: source)
    }

    #expect(declines.declines.isEmpty)
    #expect(wrapped.calls.count == sources.count * 4)
  }

  @Test func aFailedPurgeKeepsTheDeclineAndStillThrows() async throws {
    let (intents, wrapped, declines) = make()
    wrapped.stubNextCall(throwing: URLError(.cannotRemoveFile))
    await #expect(throws: URLError.self) {
      try await intents.purgeItemDownload(itemID: "book", source: .contextMenu)
    }
    #expect(declines.declines == [.init("book", nil)])
    #expect(declines.cleared.isEmpty)
  }

  @Test func aDeclineFailureNeverFailsThePurge() async throws {
    let (intents, wrapped, declines) = make()
    declines.failing = true
    try await intents.purgeEpisodeDownload(itemID: "rss:1", episodeID: "e1", source: .contextMenu)
    try await intents.purgeTombstonedEpisodeDownloads(source: .storage)
    #expect(wrapped.calls.count == 2)
  }

  @Test func handDownloadsOfAnEpisodeOrABookClearTheDecline() async throws {
    let (intents, wrapped, declines) = make()
    try await intents.requestEpisodeDownload(itemID: "rss:1", episodeID: "e1")
    try await intents.requestDownload(itemID: "book")
    #expect(declines.cleared == [.init("rss:1", "e1"), .init("book", nil)])
    #expect(
      wrapped.calls == [
        .requestEpisodeDownload(itemID: "rss:1", episodeID: "e1"), .requestDownload(itemID: "book"),
      ])
  }

  @Test func aFailedHandDownloadClearsNothing() async throws {
    let (intents, wrapped, declines) = make()
    wrapped.stubNextCall(throwing: URLError(.notConnectedToInternet))
    await #expect(throws: URLError.self) {
      try await intents.requestEpisodeDownload(itemID: "rss:1", episodeID: "e1")
    }
    wrapped.stubNextCall(throwing: URLError(.notConnectedToInternet))
    await #expect(throws: URLError.self) {
      try await intents.requestDownload(itemID: "book")
    }
    #expect(declines.cleared.isEmpty)
  }

  @Test func aClearFailureNeverFailsTheDownload() async throws {
    let (intents, wrapped, declines) = make()
    declines.failing = true
    try await intents.requestDownload(itemID: "book")
    #expect(wrapped.calls == [.requestDownload(itemID: "book")])
  }

  @Test func everythingElseIsForwardedUnchanged() async throws {
    let (intents, wrapped, declines) = make()
    // Through the decorator protocol, so these are the extension defaults a new decorator inherits.
    let decorator: any DownloadIntentsDecorator = intents
    try await decorator.requestEbookDownload(itemID: "b")
    try await decorator.requestSupplementDownload(itemID: "b", fileIno: "f")
    try await decorator.pauseEpisodeDownload(itemID: "s", episodeID: "e")
    try await decorator.resumeEpisodeDownload(itemID: "s", episodeID: "e")
    try await decorator.pauseEbookDownload(itemID: "b")
    try await decorator.resumeEbookDownload(itemID: "b")
    try await decorator.purgeEbookDownload(itemID: "b", source: .itemDetail)
    try await decorator.pauseItemDownload(itemID: "b")
    try await decorator.resumeItemDownload(itemID: "b")
    _ = await decorator.isQueuePausedForLowDisk()
    #expect(decorator.wrapped as? FakeDownloadIntents === wrapped)

    #expect(
      wrapped.calls == [
        .requestEbookDownload(itemID: "b"), .requestSupplementDownload(itemID: "b", fileIno: "f"),
        .pauseEpisodeDownload(itemID: "s", episodeID: "e"),
        .resumeEpisodeDownload(itemID: "s", episodeID: "e"), .pauseEbookDownload(itemID: "b"),
        .resumeEbookDownload(itemID: "b"), .purgeEbookDownload(itemID: "b", source: .itemDetail),
        .pauseItemDownload(itemID: "b"), .resumeItemDownload(itemID: "b"), .isQueuePausedForLowDisk,
      ])
    #expect(declines.declines.isEmpty && declines.cleared.isEmpty)
  }

  @Test func theWrappedIntentsAreExposed() {
    let (intents, wrapped, _) = make()
    #expect(intents.wrapped as? FakeDownloadIntents === wrapped)
  }

  /// The reported bug, end to end over the real queue: with Download Up Next on, a book and an
  /// episode whose downloads were removed by hand are not requested again.
  @Test func handRemovedUpNextDownloadsStayRemoved() async throws {
    let database = try AppDatabase.inMemory()
    let (accountID, book, episode) = try await Self.seedQueuedDownloads(database)
    let queue = ListeningQueueStore(database: database, accountId: accountID)
    let intents = UpNextDecliningDownloadIntents(wrapping: FakeDownloadIntents(), declining: queue)

    try await intents.purgeItemDownload(itemID: book.itemID, source: .contextMenu)
    try await intents.purgeEpisodeDownload(
      itemID: episode.itemID, episodeID: "episode-1", source: .contextMenu)
    // The fake stands in for the coordinator, so delete the rows the purges would have.
    try await database.writeAsync { db in try db.execute(sql: "DELETE FROM download") }

    let requester = RecordingRequests()
    let reconciler = QueueAutoDownloadReconciler(
      candidateProvider: queue, requesting: requester,
      preferences: AlwaysQueueAutoDownload(), networkConditions: FakeNetworkConditions(),
      declines: queue)
    await reconciler.run()
    #expect(await requester.count == 0)

    // Downloading the book again by hand lets Download Up Next keep it.
    try await intents.requestDownload(itemID: book.itemID)
    await reconciler.run()
    #expect(await requester.count == 1)
  }

  private func make() -> (UpNextDecliningDownloadIntents, FakeDownloadIntents, FakeQueueDownloadDeclines) {
    let wrapped = FakeDownloadIntents()
    let declines = FakeQueueDownloadDeclines()
    return (UpNextDecliningDownloadIntents(wrapping: wrapped, declining: declines), wrapped, declines)
  }

  private static func seedQueuedDownloads(
    _ database: AppDatabase
  ) async throws -> (Int64, ListeningIdentity, ListeningIdentity) {
    let ids = try await database.writeAsync { db in
      var account = AccountRecord(
        clientUUID: "up-next-client", serverBaseURL: "https://abs.example",
        serverUserId: "up-next-user", serverVersion: "2.35.1")
      try account.insert(db)
      var library = LibraryRecord(
        accountId: account.id!, serverLibraryId: "library", mediaType: "book", name: "Library")
      try library.insert(db)
      var book = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "book-1",
        mediaKind: "book", title: "Book", sortTitle: "book", author: "Author", numAudioFiles: 1)
      try book.insert(db)
      var show = ItemRecord(
        accountId: account.id!, libraryId: library.id!, serverItemId: "show-1",
        mediaKind: "podcast", title: "Show", sortTitle: "show")
      try show.insert(db)
      var episode = PodcastEpisodeRecord(
        accountId: account.id!, itemId: show.id!, serverEpisodeId: "episode-1",
        title: "Episode", lastSeenGeneration: 1)
      try episode.insert(db)
      return (account.id!, book.id!, show.id!, episode.id!)
    }
    let book = try #require(ListeningIdentity.audiobook(itemID: "book-1"))
    let episode = try #require(
      ListeningIdentity.podcastEpisode(itemID: "show-1", episodeID: "episode-1"))
    let queue = ListeningQueueStore(database: database, accountId: ids.0)
    try await queue.append(identity: book)
    try await queue.append(identity: episode)
    let downloads = try DownloadStore(database: database)
    _ = try await downloads.enqueueAsync(
      accountId: ids.0, itemId: ids.1, serverFileIno: "book-file", orderIndex: 0,
      destinationRelativePath: "book.m4b", expectedBytes: 100, expectedMimeType: "audio/mp4",
      fileDurationSeconds: 10)
    _ = try await downloads.enqueueAsync(
      accountId: ids.0, itemId: ids.2, podcastEpisodeId: ids.3, serverFileIno: "episode-file",
      orderIndex: 0, destinationRelativePath: "episode.m4a", expectedBytes: 100,
      expectedMimeType: "audio/mp4", fileDurationSeconds: 10)
    #expect(try await queue.fetchQueueIdentitiesWithoutDownloads().isEmpty)
    return (ids.0, book, episode)
  }
}

private struct AlwaysQueueAutoDownload: QueueAutoDownloadPolicyProviding {
  var queueAutoDownloadPolicy: QueueAutoDownloadPolicy { .always }
}

private actor RecordingRequests: QueueAutoDownloadRequesting {
  private(set) var count = 0
  func requestDownload(itemID: String) async throws { count += 1 }
  func requestEpisodeDownload(itemID: String, episodeID: String) async throws { count += 1 }
}

/// Records Up Next declines and answers which identities are declined.
final class FakeQueueDownloadDeclines: UpNextDownloadDeclining, ListeningQueueDownloadDeclineReading,
  @unchecked Sendable
{
  enum Decline: Equatable {
    case match(item: String?, episode: String?)
    case tombstoned

    init(_ item: String?, _ episode: String?) {
      self = .match(item: item, episode: episode)
    }
  }

  private let lock = NSLock()
  private var _declines: [Decline] = []
  private var _purgesSeen: [Int] = []
  private var _cleared: [Decline] = []
  private let declined: Set<ListeningIdentity>
  var failing = false
  var purgeCountAtDecline: (@Sendable () -> Int)?

  init(declined: Set<ListeningIdentity> = []) {
    self.declined = declined
  }

  var declines: [Decline] { lock.withLock { _declines } }
  var purgesSeenAtDecline: [Int] { lock.withLock { _purgesSeen } }
  var cleared: [Decline] { lock.withLock { _cleared } }

  func declineDownloads(itemID: String?, episodeID: String?, at date: Date) async throws {
    try record(.init(itemID, episodeID))
  }

  func declineTombstonedDownloads(at date: Date) async throws {
    try record(.tombstoned)
  }

  func clearDownloadDecline(itemID: String, episodeID: String?) async throws {
    if failing { throw URLError(.unknown) }
    lock.withLock { _cleared.append(.init(itemID, episodeID)) }
  }

  func isDownloadDeclined(_ identity: ListeningIdentity) async throws -> Bool {
    declined.contains(identity)
  }

  private func record(_ decline: Decline) throws {
    if failing { throw URLError(.unknown) }
    let seen = purgeCountAtDecline?() ?? 0
    lock.withLock {
      _declines.append(decline)
      _purgesSeen.append(seen)
    }
  }
}

import Foundation
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

/// Hand removal of a pinned-list download declines the member after the purge.
@Suite struct PinnedListDecliningDownloadIntentsTests {

  @Test func everyHandRemovalDeclinesAfterThePurge() async throws {
    let (intents, wrapped, declines) = make()
    try await intents.purgeItemDownload(itemID: "book-1", source: .itemDetail)
    try await intents.purgeItemDownload(itemID: "book-2", source: .contextMenu)
    try await intents.purgeItemDownload(itemID: "book-3", source: .storage)
    try await intents.purgeEpisodeDownload(itemID: "show", episodeID: "ep-1", source: .podcastEpisodeRemoval)

    #expect(wrapped.calls.count == 4)
    #expect(
      declines.declined == [
        member("book-1"), member("book-2"), member("book-3"), member("show", "ep-1"),
      ])
  }

  @Test func automaticAndReleasePurgesNeverDecline() async throws {
    let (intents, _, declines) = make()
    for source in [
      DownloadPurgeSource.storageCeiling, .finishedDownloadAutoDelete, .pinnedListRelease,
      .smartListRelease, .autoDownloadReaper, .readerEbook, .accountRemoval,
    ] {
      try await intents.purgeItemDownload(itemID: "book-1", source: source)
    }
    try await intents.purgeAllDownloads(source: .accountRemoval)

    #expect(declines.declined.isEmpty)
    #expect(declines.declinedAll == 0)
  }

  @Test func removingEveryDownloadByHandDeclinesEveryPinnedMember() async throws {
    let (intents, _, declines) = make()
    try await intents.purgeAllDownloads(source: .storage)
    #expect(declines.declinedAll == 1)
  }

  @Test func aFailedPurgeDeclinesNothing() async throws {
    let (intents, wrapped, declines) = make()
    wrapped.stubNextCall(throwing: URLError(.cannotRemoveFile))
    await #expect(throws: URLError.self) {
      try await intents.purgeItemDownload(itemID: "book-1", source: .itemDetail)
    }
    #expect(declines.declined.isEmpty)
  }

  @Test func aHandDownloadClearsTheDecline() async throws {
    let (intents, _, declines) = make()
    try await intents.requestDownload(itemID: "book-1")
    try await intents.requestEpisodeDownload(itemID: "show", episodeID: "ep-1")
    #expect(declines.cleared == [member("book-1"), member("show", "ep-1")])
  }

  @Test func aDeclineFailureNeverFailsThePurge() async throws {
    let (intents, _, declines) = make()
    declines.failing = true
    try await intents.purgeItemDownload(itemID: "book-1", source: .itemDetail)
  }

  @Test func everythingElseIsForwardedUnchanged() async throws {
    let (intents, wrapped, _) = make()
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
    try await decorator.purgeTombstonedEpisodeDownloads(source: .storage)
    _ = await decorator.isQueuePausedForLowDisk()
    #expect(decorator.wrapped as? FakeDownloadIntents === wrapped)
    #expect(
      wrapped.calls == [
        .requestEbookDownload(itemID: "b"), .requestSupplementDownload(itemID: "b", fileIno: "f"),
        .pauseEpisodeDownload(itemID: "s", episodeID: "e"),
        .resumeEpisodeDownload(itemID: "s", episodeID: "e"), .pauseEbookDownload(itemID: "b"),
        .resumeEbookDownload(itemID: "b"), .purgeEbookDownload(itemID: "b", source: .itemDetail),
        .pauseItemDownload(itemID: "b"), .resumeItemDownload(itemID: "b"),
        .purgeTombstonedEpisodeDownloads(source: .storage), .isQueuePausedForLowDisk,
      ])
  }

  private func make() -> (PinnedListDecliningDownloadIntents, FakeDownloadIntents, FakePinnedListDeclining) {
    let wrapped = FakeDownloadIntents()
    let declines = FakePinnedListDeclining()
    return (PinnedListDecliningDownloadIntents(wrapping: wrapped, declining: declines, accountID: 1), wrapped, declines)
  }

  private func member(_ item: String, _ episode: String? = nil) -> PinnedListMember {
    PinnedListMember(serverItemID: item, serverEpisodeID: episode)
  }
}

final class FakePinnedListDeclining: PinnedListDeclining, @unchecked Sendable {
  private let lock = NSLock()
  private var _declined: [PinnedListMember] = []
  private var _cleared: [PinnedListMember] = []
  private var _declinedAll = 0
  var failing = false

  var declined: [PinnedListMember] { lock.withLock { _declined } }
  var cleared: [PinnedListMember] { lock.withLock { _cleared } }
  var declinedAll: Int { lock.withLock { _declinedAll } }

  func decline(accountID: Int64, member: PinnedListMember, at date: Date) async throws {
    if failing { throw URLError(.unknown) }
    lock.withLock { _declined.append(member) }
  }

  func declineAll(accountID: Int64, at date: Date) async throws {
    lock.withLock { _declinedAll += 1 }
  }

  func clearDeclines(accountID: Int64, member: PinnedListMember) async throws {
    lock.withLock { _cleared.append(member) }
  }
}

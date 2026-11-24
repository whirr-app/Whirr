import Foundation
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

/// A hand removal declines what smart lists want before the purge and drops their claims after
/// it; a hand episode download clears the decline.
@Suite struct SmartListDecliningDownloadIntentsTests {

  @Test func everyHandRemovalDeclinesWhatTheListsWantBeforeItPurges() async throws {
    let (intents, wrapped, declines) = make()
    declines.purgeCountAtDecline = { wrapped.calls.count }
    try await intents.purgeEpisodeDownload(itemID: "rss:1", episodeID: "e1", source: .podcastEpisodeRemoval)
    try await intents.purgeEpisodeDownload(itemID: "show", episodeID: "s1", source: .contextMenu)
    try await intents.purgeItemDownload(itemID: "rss:2", source: .itemDetail)
    try await intents.purgeItemDownload(itemID: "show", source: .storage)
    try await intents.purgeAllDownloads(source: .storage)

    #expect(
      declines.declines == [
        .init("rss:1", "e1"), .init("show", "s1"), .init("rss:2", nil), .init("show", nil),
        .init(nil, nil),
      ])
    // Each decline saw only the purges before it, so it was written ahead of its own purge.
    #expect(declines.purgesSeenAtDecline == [0, 1, 2, 3, 4])
    #expect(wrapped.calls.count == 5)
  }

  @Test func automaticAndReleasePurgesNeverDecline() async throws {
    let (intents, wrapped, declines) = make()
    for source in [
      DownloadPurgeSource.storageCeiling, .finishedDownloadAutoDelete, .pinnedListRelease,
      .smartListRelease, .autoDownloadReaper, .readerEbook, .accountRemoval,
    ] {
      try await intents.purgeEpisodeDownload(itemID: "rss:1", episodeID: "e1", source: source)
      try await intents.purgeItemDownload(itemID: "rss:1", source: source)
    }
    try await intents.purgeAllDownloads(source: .accountRemoval)

    #expect(declines.declines.isEmpty)
    #expect(declines.droppedClaims.isEmpty)
    #expect(wrapped.calls.count == 15)
  }

  @Test func claimsOfWhatWasDeclinedAreDroppedOnceThePurgeSucceeds() async throws {
    let (intents, _, declines) = make()
    declines.result = [SmartListEpisodeIdentity(itemID: "rss:1", episodeID: "e1")]
    try await intents.purgeEpisodeDownload(itemID: "rss:1", episodeID: "e1", source: .contextMenu)
    #expect(declines.droppedClaims == [[SmartListEpisodeIdentity(itemID: "rss:1", episodeID: "e1")]])
  }

  @Test func aFailedPurgeKeepsTheDeclineAndTheClaimsAndStillThrows() async throws {
    let (intents, wrapped, declines) = make()
    declines.result = [SmartListEpisodeIdentity(itemID: "rss:1", episodeID: "e1")]
    wrapped.stubNextCall(throwing: URLError(.cannotRemoveFile))
    await #expect(throws: URLError.self) {
      try await intents.purgeEpisodeDownload(itemID: "rss:1", episodeID: "e1", source: .contextMenu)
    }
    #expect(declines.declines == [.init("rss:1", "e1")])
    #expect(declines.droppedClaims.isEmpty)
  }

  @Test func aDeclineFailureNeverFailsThePurge() async throws {
    let (intents, wrapped, declines) = make()
    declines.failing = true
    try await intents.purgeEpisodeDownload(itemID: "rss:1", episodeID: "e1", source: .contextMenu)
    #expect(wrapped.calls.count == 1)
  }

  @Test func aHandEpisodeDownloadClearsTheDeclineAndAWholeItemRequestDoesNot() async throws {
    let (intents, wrapped, declines) = make()
    try await intents.requestEpisodeDownload(itemID: "rss:1", episodeID: "e1")
    try await intents.requestDownload(itemID: "book")
    #expect(declines.cleared == [.init("rss:1", "e1")])
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
    #expect(declines.cleared.isEmpty)
  }

  @Test func withNoAccountItStillDeclinesAndPassesNoAccountOn() async throws {
    let wrapped = FakeDownloadIntents()
    let declines = FakeSmartListDeclining()
    let intents = SmartListDecliningDownloadIntents(wrapping: wrapped, declining: declines, accountID: nil)
    try await intents.purgeEpisodeDownload(itemID: "rss:1", episodeID: "e1", source: .contextMenu)
    #expect(declines.declines == [.init("rss:1", "e1")])
    #expect(declines.accounts == [nil])
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
    #expect(declines.declines.isEmpty && declines.cleared.isEmpty)
  }

  private func make() -> (SmartListDecliningDownloadIntents, FakeDownloadIntents, FakeSmartListDeclining) {
    let wrapped = FakeDownloadIntents()
    let declines = FakeSmartListDeclining()
    return (SmartListDecliningDownloadIntents(wrapping: wrapped, declining: declines, accountID: 7), wrapped, declines)
  }
}

final class FakeSmartListDeclining: SmartListDeclining, @unchecked Sendable {
  struct Match: Equatable {
    let item: String?
    let episode: String?

    init(_ item: String?, _ episode: String?) {
      self.item = item
      self.episode = episode
    }
  }

  private let lock = NSLock()
  private var _declines: [Match] = []
  private var _accounts: [Int64?] = []
  private var _purgesSeen: [Int] = []
  private var _dropped: [[SmartListEpisodeIdentity]] = []
  private var _cleared: [Match] = []
  var failing = false
  var result: [SmartListEpisodeIdentity] = []
  var purgeCountAtDecline: (@Sendable () -> Int)?

  var declines: [Match] { lock.withLock { _declines } }
  var accounts: [Int64?] { lock.withLock { _accounts } }
  var purgesSeenAtDecline: [Int] { lock.withLock { _purgesSeen } }
  var droppedClaims: [[SmartListEpisodeIdentity]] { lock.withLock { _dropped } }
  var cleared: [Match] { lock.withLock { _cleared } }

  func declineWanted(itemID: String?, episodeID: String?, accountID: Int64?, at date: Date)
    async throws -> [SmartListEpisodeIdentity]
  {
    if failing { throw URLError(.unknown) }
    let seen = purgeCountAtDecline?() ?? 0
    lock.withLock {
      _declines.append(Match(itemID, episodeID))
      _accounts.append(accountID)
      _purgesSeen.append(seen)
    }
    return result
  }

  func dropClaims(episodes: [SmartListEpisodeIdentity]) async throws {
    guard episodes.isEmpty == false else { return }
    lock.withLock { _dropped.append(episodes) }
  }

  func clearDecline(itemID: String, episodeID: String?) async throws {
    lock.withLock { _cleared.append(Match(itemID, episodeID)) }
  }
}

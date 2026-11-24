import Foundation
import GRDB
import Persistence
import PlayerCore
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// The behaviour every podcast episode action must have whichever source owns the episode. Each
/// scenario runs once per source against the graph production composes, so a rule that drifts for
/// one source fails here instead of in a device pass. Where the sources differ on purpose, the
/// assertion branches on `source` and says why.
@MainActor
@Suite("Podcast episode intents contract")
struct PodcastEpisodeIntentsContractTests {
  enum Source: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case abs
    case rss

    var testDescription: String { rawValue }
  }

  // MARK: - Play, queue and saved

  @Test(arguments: Source.allCases)
  func playStartsTheSharedPlaybackModel(source: Source) async throws {
    let harness = try await ContractHarness.make(source)
    harness.sync.stubStartSession(.success(harness.prepared(episodeID: "episode-a")))

    try await harness.intents.play(itemID: harness.itemID, episodeID: "episode-a")

    #expect(
      harness.sync.calls.contains(.startSession(itemID: harness.itemID, episodeID: "episode-a")))
    #expect(harness.playback.activeItemID == harness.itemID)
    #expect(harness.playback.activeEpisodeID == "episode-a")
  }

  @Test(arguments: Source.allCases)
  func queueActionsWriteTheSourcesListeningIdentity(source: Source) async throws {
    let harness = try await ContractHarness.make(source)

    try await harness.intents.playNext(itemID: harness.itemID, episodeID: "episode-a")
    try await harness.intents.addToUpNext(itemID: harness.itemID, episodeID: "episode-b")

    let expected: [ListeningIdentity]
    switch source {
    case .abs:
      expected = [
        try #require(ListeningIdentity.podcastEpisode(itemID: harness.itemID, episodeID: "episode-a")),
        try #require(ListeningIdentity.podcastEpisode(itemID: harness.itemID, episodeID: "episode-b")),
      ]
    case .rss:
      let feedID = try #require(PodcastSourceIdentity(itemId: harness.itemID)?.rssFeedId)
      expected = [
        try #require(ListeningIdentity.rssEpisode(feedID: feedID, episodeID: "episode-a")),
        try #require(ListeningIdentity.rssEpisode(feedID: feedID, episodeID: "episode-b")),
      ]
    }
    #expect(harness.queue.mutations == [.insertNext(expected[0]), .append(expected[1])])
  }

  @Test(arguments: Source.allCases)
  func anUnresolvableQueueIdentityFailsWithTheActionCopy(source: Source) async throws {
    let harness = try await ContractHarness.make(source)

    try await expectFailure(PodcastCopy.actionFailed) {
      try await harness.intents.playNext(itemID: harness.itemID, episodeID: "")
    }
    try await expectFailure(PodcastCopy.actionFailed) {
      try await harness.intents.addToUpNext(itemID: harness.itemID, episodeID: "")
    }
    #expect(harness.queue.mutations.isEmpty)
  }

  @Test(arguments: Source.allCases)
  func aQueueFailurePassesThroughUnchanged(source: Source) async throws {
    let harness = try await ContractHarness.make(source)
    harness.queue.failNext(ContractFailure())

    await #expect(throws: ContractFailure.self) {
      try await harness.intents.playNext(itemID: harness.itemID, episodeID: "episode-a")
    }
  }

  @Test(arguments: Source.allCases)
  func savedActionsWriteTheSourcesSavedIdentityAndReturnTheShelfOutcome(
    source: Source
  ) async throws {
    let harness = try await ContractHarness.make(source)
    let identity = try #require(
      SavedShelfIdentity.resolving(itemID: harness.itemID, episodeID: "episode-a"))
    switch source {
    case .abs: #expect(identity == .podcastEpisode(itemID: harness.itemID, episodeID: "episode-a"))
    case .rss: #expect(identity == .rssEpisode(itemID: harness.itemID, episodeID: "episode-a"))
    }

    #expect(try await harness.intents.saveForLater(itemID: harness.itemID, episodeID: "episode-a") == .saved)
    harness.savedShelf.stubSaveOutcome(.alreadySaved)
    #expect(
      try await harness.intents.saveForLater(itemID: harness.itemID, episodeID: "episode-a")
        == .alreadySaved)
    try await harness.intents.removeFromSaved(itemID: harness.itemID, episodeID: "episode-a")

    #expect(harness.savedShelf.calls == [.save(identity), .save(identity), .remove(identity)])
  }

  @Test(arguments: Source.allCases)
  func savedFailuresUseTheSavedForLaterCopy(source: Source) async throws {
    let harness = try await ContractHarness.make(source)

    harness.savedShelf.failNext(ContractFailure())
    try await expectFailure(SavedForLaterCopy.saveFailed) {
      _ = try await harness.intents.saveForLater(itemID: harness.itemID, episodeID: "episode-a")
    }
    harness.savedShelf.failNext(ContractFailure())
    try await expectFailure(SavedForLaterCopy.removeFailed) {
      try await harness.intents.removeFromSaved(itemID: harness.itemID, episodeID: "episode-a")
    }
  }

  // MARK: - Downloads

  @Test(arguments: Source.allCases)
  func downloadActionsReachTheSharedDownloadIntents(source: Source) async throws {
    let harness = try await ContractHarness.make(source)
    let itemID = harness.itemID

    try await harness.intents.download(itemID: itemID, episodeID: "episode-a")
    try await harness.intents.pauseDownload(itemID: itemID, episodeID: "episode-a")
    try await harness.intents.resumeDownload(itemID: itemID, episodeID: "episode-a")
    try await harness.intents.removeDownload(itemID: itemID, episodeID: "episode-a")

    #expect(
      harness.downloads.calls == [
        .requestEpisodeDownload(itemID: itemID, episodeID: "episode-a"),
        .pauseEpisodeDownload(itemID: itemID, episodeID: "episode-a"),
        .resumeEpisodeDownload(itemID: itemID, episodeID: "episode-a"),
        .purgeEpisodeDownload(itemID: itemID, episodeID: "episode-a", source: .podcastEpisodeRemoval),
      ])
  }

  @Test(arguments: Source.allCases)
  func aDownloadFailurePassesThroughUnchanged(source: Source) async throws {
    let harness = try await ContractHarness.make(source)
    harness.downloads.stubNextCall(throwing: ContractFailure())

    await #expect(throws: ContractFailure.self) {
      try await harness.intents.download(itemID: harness.itemID, episodeID: "episode-a")
    }
    await #expect(throws: ContractFailure.self) {
      try await harness.intents.pauseDownload(itemID: harness.itemID, episodeID: "episode-a")
    }
    await #expect(throws: ContractFailure.self) {
      try await harness.intents.resumeDownload(itemID: harness.itemID, episodeID: "episode-a")
    }
    await #expect(throws: ContractFailure.self) {
      try await harness.intents.removeDownload(itemID: harness.itemID, episodeID: "episode-a")
    }
  }

  // MARK: - Finish

  @Test(arguments: Source.allCases)
  func finishingTheActiveEpisodeStopsPlaybackBeforeTheDurableWrite(source: Source) async throws {
    let harness = try await ContractHarness.make(source)
    await harness.start(episodeID: "episode-a")

    try await harness.intents.markAsFinished(
      itemID: harness.itemID, episodeID: "episode-a", duration: 120)

    #expect(harness.player.intents.contains(.stop))
    #expect(try await harness.state("episode-a")?.finished == true)
    if source == .abs {
      #expect(await harness.absProgress.playerIntentsAtFinish.last == .stop)
    }
  }

  @Test(arguments: Source.allCases)
  func finishingASiblingEpisodeLeavesPlaybackAlone(source: Source) async throws {
    let harness = try await ContractHarness.make(source)
    await harness.start(episodeID: "episode-a")
    let baseline = harness.player.intents

    try await harness.intents.markAsFinished(
      itemID: harness.itemID, episodeID: "episode-b", duration: 120)

    #expect(harness.player.intents == baseline)
    #expect(try await harness.state("episode-b")?.finished == true)
  }

  /// The stop is not undone by a failed write: it comes first, so a finish that does not land
  /// still leaves the episode stopped.
  @Test(arguments: Source.allCases)
  func aFailedFinishOfTheActiveEpisodeHasAlreadyStopped(source: Source) async throws {
    let harness = try await ContractHarness.make(source)
    await harness.start(episodeID: ContractHarness.missingEpisodeID)

    await #expect(throws: (any Error).self) {
      try await harness.intents.markAsFinished(
        itemID: harness.itemID, episodeID: ContractHarness.missingEpisodeID, duration: nil)
    }
    #expect(harness.player.intents.last == .stop)
  }

  /// Difference 4: ABS records `duration` as the finished position; the device-owned state keeps
  /// `finished` as its own column and leaves the position where it was.
  @Test(arguments: Source.allCases)
  func finishDurationIsRecordedOnlyByTheServerSource(source: Source) async throws {
    let harness = try await ContractHarness.make(source)

    try await harness.intents.markAsFinished(
      itemID: harness.itemID, episodeID: "episode-a", duration: 120)

    switch source {
    case .abs:
      #expect(await harness.absProgress.calls == [.finish(harness.itemID, "episode-a", 120)])
    case .rss:
      #expect(try await harness.state("episode-a")?.position == 0)
    }
  }

  // MARK: - Finish continuation

  /// A finish that leaves nothing to continue stops, writes, and lets presence clear through the
  /// finished bookmark; nothing may be started over it.
  @Test(arguments: Source.allCases)
  func finishingTheActiveEpisodeWithNothingQueuedClearsPresence(source: Source) async throws {
    let harness = try await ContractHarness.make(source)
    await harness.start(episodeID: "episode-a")
    harness.bookmarks.push(harness.bookmark(episodeID: "episode-a", isFinished: true))

    try await harness.intents.markAsFinished(
      itemID: harness.itemID, episodeID: "episode-a", duration: 120)

    #expect(harness.player.intents.contains(.stop))
    #expect(harness.playback.activeItemID == nil)
    #expect(harness.queue.peekCount == 1, "the preparation peeks the empty queue once")
    #expect(await waitUntil { harness.playback.nowPlayingIdentity == nil })
  }

  /// D3: the next continuation is prepared paused. A row opens a session and loads, but nothing
  /// plays, and the finished episode's own row is gone before the peek.
  @Test(arguments: Source.allCases)
  func finishingTheActiveEpisodePreparesTheNextRowPaused(source: Source) async throws {
    let harness = try await ContractHarness.make(source)
    await harness.start(episodeID: "episode-a")
    let next = try #require(harness.listeningIdentity(episodeID: "episode-b"))
    harness.queue.stubRows([harness.queueRow(1, next)])
    harness.sync.stubStartSession(.success(harness.prepared(episodeID: "episode-b")))
    let baseline = harness.player.intents

    try await harness.intents.markAsFinished(
      itemID: harness.itemID, episodeID: "episode-a", duration: 120)

    let sent = Array(harness.player.intents.dropFirst(baseline.count))
    #expect(sent.contains(.play) == false, "finishing the title must not resume audio")
    #expect(sent.contains { if case .load = $0 { true } else { false } })
    #expect(harness.playback.loadedItemID == harness.itemID)
    #expect(harness.playback.loadedEpisodeID == "episode-b")
    #expect(harness.playback.startFailure == nil)
    #expect(
      harness.queue.removed
        == [try #require(harness.listeningIdentity(episodeID: "episode-a"))])
    #expect(harness.queue.identities.isEmpty, "the prepared row is consumed")
  }

  @Test(arguments: Source.allCases)
  func finishingAnInactiveEpisodePreparesNothing(source: Source) async throws {
    let harness = try await ContractHarness.make(source)
    await harness.start(episodeID: "episode-a")
    let queued = try #require(harness.listeningIdentity(episodeID: "episode-c"))
    harness.queue.stubRows([harness.queueRow(1, queued)])
    let baseline = harness.player.intents

    try await harness.intents.markAsFinished(
      itemID: harness.itemID, episodeID: "episode-b", duration: 120)

    #expect(harness.player.intents == baseline)
    #expect(harness.queue.peekCount == 0)
    #expect(harness.queue.removed.isEmpty)
    #expect(harness.queue.identities == [queued])
    #expect(harness.playback.activeEpisodeID == "episode-a", "the sibling keeps playing")
  }

  /// The stop already happened, but a failed write leaves the episode unfinished and retained, so
  /// no continuation may be prepared over it.
  @Test(arguments: Source.allCases)
  func aFailedFinishOfTheActiveEpisodePreparesNothing(source: Source) async throws {
    let harness = try await ContractHarness.make(source)
    let missing = ContractHarness.missingEpisodeID
    await harness.start(episodeID: missing)
    harness.bookmarks.push(harness.bookmark(episodeID: missing, isFinished: false))
    let identity = try #require(harness.listeningIdentity(episodeID: missing))
    await waitUntil { harness.playback.nowPlayingIdentity == identity }
    let queued = try #require(harness.listeningIdentity(episodeID: "episode-c"))
    harness.queue.stubRows([harness.queueRow(1, queued)])
    let baseline = harness.player.intents

    await #expect(throws: (any Error).self) {
      try await harness.intents.markAsFinished(
        itemID: harness.itemID, episodeID: missing, duration: nil)
    }

    #expect(Array(harness.player.intents.dropFirst(baseline.count)) == [.stop])
    #expect(harness.queue.peekCount == 0)
    #expect(harness.queue.identities == [queued])
    #expect(harness.playback.nowPlayingIdentity == identity)
  }

  // MARK: - Reset

  @Test(arguments: Source.allCases)
  func resettingTheActiveEpisodeSeeksToZeroAfterTheDurableReset(source: Source) async throws {
    let harness = try await ContractHarness.make(source)
    try await harness.intents.markAsFinished(
      itemID: harness.itemID, episodeID: "episode-a", duration: 120)
    await harness.start(episodeID: "episode-a")
    let baseline = harness.player.intents

    try await harness.intents.resetProgress(itemID: harness.itemID, episodeID: "episode-a")

    #expect(harness.player.intents.last == .seek(toGlobalOffset: 0))
    let state = try await harness.state("episode-a")
    #expect(state?.finished == false)
    #expect(state?.position == 0)
    if source == .abs {
      #expect(await harness.absProgress.playerIntentsAtReset == baseline)
    }
  }

  @Test(arguments: Source.allCases)
  func resettingASiblingEpisodeLeavesPlaybackAlone(source: Source) async throws {
    let harness = try await ContractHarness.make(source)
    await harness.start(episodeID: "episode-a")
    let baseline = harness.player.intents

    try await harness.intents.resetProgress(itemID: harness.itemID, episodeID: "episode-b")

    #expect(harness.player.intents == baseline)
    #expect(try await harness.state("episode-b")?.position == 0)
  }

  /// Durable first: a reset that does not land must not move the live playhead.
  @Test(arguments: Source.allCases)
  func aFailedResetOfTheActiveEpisodeDoesNotSeek(source: Source) async throws {
    let harness = try await ContractHarness.make(source)
    await harness.start(episodeID: ContractHarness.missingEpisodeID)
    let baseline = harness.player.intents

    await #expect(throws: (any Error).self) {
      try await harness.intents.resetProgress(
        itemID: harness.itemID, episodeID: ContractHarness.missingEpisodeID)
    }
    #expect(harness.player.intents == baseline)
  }

  // MARK: - Continue Listening

  @Test(arguments: Source.allCases)
  func removeFromContinueListeningHidesOnlyTheNamedEpisode(source: Source) async throws {
    let harness = try await ContractHarness.make(source)
    await harness.start(episodeID: "episode-a")
    let baseline = harness.player.intents

    try await harness.intents.removeFromContinueListening(
      itemID: harness.itemID, episodeID: "episode-a")

    #expect(try await harness.state("episode-a")?.hidden == true)
    #expect(try await harness.state("episode-b")?.hidden != true)
    #expect(harness.player.intents == baseline)
  }

  // MARK: - Mark all

  /// No playback interlock on the bulk action, for either source.
  @Test(arguments: Source.allCases)
  func markAllWritesEverySuppliedEpisodeWithoutTouchingPlayback(source: Source) async throws {
    let harness = try await ContractHarness.make(source)
    await harness.start(episodeID: "episode-a")
    let baseline = harness.player.intents
    let changes = ["episode-a", "episode-b"].map {
      EpisodeProgressChange(episodeID: $0, currentTime: 120)
    }

    try await harness.intents.markAll(itemID: harness.itemID, episodes: changes, isFinished: true)
    #expect(try await harness.state("episode-a")?.finished == true)
    #expect(try await harness.state("episode-b")?.finished == true)
    #expect(try await harness.state("episode-c")?.finished != true)

    try await harness.intents.markAll(itemID: harness.itemID, episodes: changes, isFinished: false)
    #expect(try await harness.state("episode-a")?.finished == false)
    #expect(try await harness.state("episode-b")?.finished == false)

    #expect(harness.player.intents == baseline)
  }

  /// An empty bulk mark returns early for both sources and writes nothing.
  @Test(arguments: Source.allCases)
  func anEmptyMarkAll(source: Source) async throws {
    let harness = try await ContractHarness.make(source)

    try await harness.intents.markAll(itemID: harness.itemID, episodes: [], isFinished: true)

    switch source {
    case .abs:
      #expect(await harness.absProgress.calls.isEmpty)
    case .rss:
      #expect(try await harness.rssStateRowCount() == 0)
    }
  }

  // MARK: - Progress failure copy

  /// Every progress failure becomes the copy for its operation, whatever the backend threw.
  @Test(arguments: Source.allCases)
  func progressFailuresAndTheirCopy(source: Source) async throws {
    let harness = try await ContractHarness.make(source)
    let missing = ContractHarness.missingEpisodeID
    let itemID = harness.itemID

    let operations: [(String, () async throws -> Void)] = [
      (
        "markAsFinished",
        { try await harness.intents.markAsFinished(itemID: itemID, episodeID: missing, duration: nil) }
      ),
      ("resetProgress", { try await harness.intents.resetProgress(itemID: itemID, episodeID: missing) }),
      (
        "markAll",
        {
          try await harness.intents.markAll(
            itemID: itemID,
            episodes: [
              EpisodeProgressChange(episodeID: "episode-a", currentTime: 0),
              EpisodeProgressChange(episodeID: missing, currentTime: 0),
            ],
            isFinished: true)
        }
      ),
    ]
    for (name, operation) in operations {
      do {
        try await operation()
        Issue.record("\(name) unexpectedly succeeded")
      } catch {
        #expect(
          error as? PodcastEpisodeIntentFailure == PodcastEpisodeIntentFailure(message: PodcastCopy.actionFailed),
          "\(name)")
        #expect(PodcastEpisodeIntentExecutor.errorMessage(for: error) == PodcastCopy.actionFailed, "\(name)")
      }
    }

    try await expectFailure(ContinueListeningCopy.removeFailed) {
      try await harness.intents.removeFromContinueListening(itemID: itemID, episodeID: missing)
    }
  }

  // MARK: - Undecodable ids

  /// Episode actions are direct taps, so a malformed id is a visible failure rather than a silent
  /// no-op, and nothing anywhere is touched on the way.
  @Test func anUndecodableItemIDFailsEveryActionWithoutSideEffects() async throws {
    let harness = try await ContractHarness.make(.abs)
    let intents = harness.intents
    let operations: [(String, (String) async throws -> Void)] = [
      ("play", { try await intents.play(itemID: $0, episodeID: "episode-a") }),
      ("playNext", { try await intents.playNext(itemID: $0, episodeID: "episode-a") }),
      ("addToUpNext", { try await intents.addToUpNext(itemID: $0, episodeID: "episode-a") }),
      ("saveForLater", { _ = try await intents.saveForLater(itemID: $0, episodeID: "episode-a") }),
      ("removeFromSaved", { try await intents.removeFromSaved(itemID: $0, episodeID: "episode-a") }),
      ("download", { try await intents.download(itemID: $0, episodeID: "episode-a") }),
      ("pauseDownload", { try await intents.pauseDownload(itemID: $0, episodeID: "episode-a") }),
      ("resumeDownload", { try await intents.resumeDownload(itemID: $0, episodeID: "episode-a") }),
      ("removeDownload", { try await intents.removeDownload(itemID: $0, episodeID: "episode-a") }),
      (
        "markAsFinished",
        { try await intents.markAsFinished(itemID: $0, episodeID: "episode-a", duration: nil) }
      ),
      ("resetProgress", { try await intents.resetProgress(itemID: $0, episodeID: "episode-a") }),
      (
        "removeFromContinueListening",
        { try await intents.removeFromContinueListening(itemID: $0, episodeID: "episode-a") }
      ),
      ("markAll", { try await intents.markAll(itemID: $0, episodes: [], isFinished: true) }),
      (
        "markAll",
        {
          try await intents.markAll(
            itemID: $0, episodes: [EpisodeProgressChange(episodeID: "episode-a", currentTime: 0)],
            isFinished: true)
        }
      ),
    ]

    for itemID in ["", "rss:007"] {
      for (name, operation) in operations {
        do {
          try await operation(itemID)
          Issue.record("\(name) unexpectedly succeeded for \(itemID.debugDescription)")
        } catch {
          #expect(
            error as? PodcastEpisodeIntentFailure
              == PodcastEpisodeIntentFailure(message: PodcastCopy.actionFailed),
            "\(name), \(itemID.debugDescription)")
        }
      }
    }

    #expect(harness.sync.calls.contains { if case .startSession = $0 { true } else { false } } == false)
    #expect(harness.queue.mutations.isEmpty)
    #expect(harness.savedShelf.calls.isEmpty)
    #expect(harness.downloads.calls.isEmpty)
    #expect(await harness.absProgress.calls.isEmpty)
    #expect(try await harness.rssStateRowCount() == 0)
  }

  private func expectFailure(
    _ message: String, sourceLocation: SourceLocation = #_sourceLocation,
    _ operation: () async throws -> Void
  ) async throws {
    do {
      try await operation()
      Issue.record("expected a failure with \(message.debugDescription)", sourceLocation: sourceLocation)
    } catch {
      #expect(
        error as? PodcastEpisodeIntentFailure == PodcastEpisodeIntentFailure(message: message),
        sourceLocation: sourceLocation)
    }
  }
}

// MARK: - Harness

private struct ContractFailure: Error {}

/// Both sources live in one graph, as they do in production; `source` only picks which item the
/// scenario acts on and where its progress is read back from.
@MainActor
private final class ContractHarness {
  nonisolated static let missingEpisodeID = "missing"

  let source: PodcastEpisodeIntentsContractTests.Source
  let itemID: String
  let intents: any PodcastEpisodeIntents
  let playback: PlaybackModel
  let player: FakePlaybackControlling
  let sync: FakePlaybackSyncing
  let queue: FakeListeningQueueStoring
  let savedShelf: FakeSavedShelfStoring
  let downloads: FakeDownloadIntents
  let absProgress: ContractItemProgressIntents
  let bookmarks: FakePlaybackBookmarkStoring
  let database: AppDatabase
  let rssItemID: String
  let rssEpisodeIDs: [String: Int64]

  private init(
    source: PodcastEpisodeIntentsContractTests.Source, intents: any PodcastEpisodeIntents,
    playback: PlaybackModel, player: FakePlaybackControlling, sync: FakePlaybackSyncing,
    queue: FakeListeningQueueStoring, savedShelf: FakeSavedShelfStoring,
    downloads: FakeDownloadIntents,
    absProgress: ContractItemProgressIntents, bookmarks: FakePlaybackBookmarkStoring,
    database: AppDatabase, rssItemID: String, rssEpisodeIDs: [String: Int64]
  ) {
    self.source = source
    self.itemID = source == .abs ? "li_show" : rssItemID
    self.intents = intents
    self.playback = playback
    self.player = player
    self.sync = sync
    self.queue = queue
    self.savedShelf = savedShelf
    self.downloads = downloads
    self.absProgress = absProgress
    self.bookmarks = bookmarks
    self.database = database
    self.rssItemID = rssItemID
    self.rssEpisodeIDs = rssEpisodeIDs
  }

  static func make(_ source: PodcastEpisodeIntentsContractTests.Source) async throws -> ContractHarness {
    let queue = FakeListeningQueueStoring()
    let bookmarks = FakePlaybackBookmarkStoring()
    let playbackHarness = PlaybackModelHarness(bookmarkStore: bookmarks, listeningQueue: queue)
    let player = playbackHarness.player
    let sync = playbackHarness.sync
    let playback = playbackHarness.model
    let savedShelf = FakeSavedShelfStoring()
    let downloads = FakeDownloadIntents()
    let absProgress = ContractItemProgressIntents(player: player)
    let rss = try await makeRSSFixture()
    let intents = makeIntents(
      playback: playback, queue: queue, savedShelf: savedShelf, downloads: downloads,
      absProgress: absProgress, database: rss.database)
    return ContractHarness(
      source: source, intents: intents, playback: playback, player: player, sync: sync,
      queue: queue, savedShelf: savedShelf, downloads: downloads, absProgress: absProgress,
      bookmarks: bookmarks, database: rss.database, rssItemID: rss.itemID,
      rssEpisodeIDs: rss.episodeIDs)
  }

  /// The production composition (`AppEnvironment+RuntimeDependencies.swift`), with fakes for
  /// everything except the device-owned stores.
  private static func makeIntents(
    playback: PlaybackModel, queue: FakeListeningQueueStoring, savedShelf: FakeSavedShelfStoring,
    downloads: FakeDownloadIntents, absProgress: ContractItemProgressIntents, database: AppDatabase
  ) -> any PodcastEpisodeIntents {
    PlaybackPodcastEpisodeIntents(
      playback: playback, queue: queue, downloadIntents: downloads,
      progress: RoutingPodcastEpisodeProgressBackend(
        abs: ABSEpisodeProgressBackend(progressIntents: absProgress),
        rss: RSSEpisodeProgressBackend(
          episodeStore: RSSEpisodeStore(database: database),
          stateStore: RSSEpisodeStateStore(database: database),
          downloadPreferences: NoOpDownloadPreferences(),
          requestFinishedDownloadDeletion: { _, _ in })),
      savedShelf: savedShelf)
  }

  func prepared(episodeID: String) -> PreparedPlayback {
    PlaybackFixture.prepared(
      itemID: itemID, episodeID: episodeID, startPosition: 0, duration: 120,
      tracks: [
        PlaybackFixture.track(
          index: 0, startOffset: 0, duration: 120,
          url: URL(string: "https://media.example/\(episodeID).mp3")!, mimeType: "audio/mpeg",
          title: episodeID)
      ], chapters: [])
  }

  func start(episodeID: String) async {
    sync.stubStartSession(.success(prepared(episodeID: episodeID)))
    await playback.start(itemID: itemID, episodeID: episodeID)
  }

  /// The identity this source's queue stores for one of its episodes.
  func listeningIdentity(episodeID: String) -> ListeningIdentity? {
    ListeningIdentity.resolving(itemID: itemID, episodeID: episodeID)
  }

  func queueRow(_ id: Int64, _ identity: ListeningIdentity) -> ListeningQueueItem {
    ListeningQueueItem(
      id: id, position: Int(id) - 1, identity: identity, primaryTitle: "Row \(id)",
      secondaryTitle: "Secondary",
      category: identity.episodeID == nil ? .audiobook : .podcast, isTombstone: false,
      chapter: nil)
  }

  /// The retained bookmark the player's presence falls back to, as the store would project it.
  func bookmark(episodeID: String, isFinished: Bool) -> PlaybackBookmark {
    PlaybackBookmark(
      serverItemId: itemID, episodeID: episodeID, episodeTitle: episodeID,
      showTitle: "Show", title: episodeID, author: nil, durationSeconds: 120,
      positionSeconds: isFinished ? 120 : 30, isFinished: isFinished)
  }

  struct EpisodeState: Equatable {
    var finished: Bool
    var position: Double
    var hidden: Bool
  }

  /// The durable state of one episode of this harness's source, `nil` when nothing was written.
  func state(_ episodeID: String) async throws -> EpisodeState? {
    switch source {
    case .abs:
      return await absProgress.states[episodeID]
    case .rss:
      guard let rowID = rssEpisodeIDs[episodeID] else { return nil }
      guard let record = try await RSSEpisodeStateStore(database: database).fetchState(episodeId: rowID)
      else { return nil }
      return EpisodeState(
        finished: record.finished, position: record.position,
        hidden: record.hideFromContinueListening)
    }
  }

  func rssStateRowCount() async throws -> Int {
    try await database.readAsync { db in try RSSEpisodeStateRecord.fetchCount(db) }
  }

  private static func makeRSSFixture() async throws -> (
    database: AppDatabase, itemID: String, episodeIDs: [String: Int64]
  ) {
    let database = try AppDatabase.inMemory()
    let feedID = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/feed-\(UUID().uuidString).xml")!,
      title: "Feed", author: nil, synopsis: nil, artworkURL: nil, subscribedAt: Date())
    let episodes = ["episode-a", "episode-b", "episode-c"].map {
      RSSEpisodeUpsert(
        identityKey: $0, title: $0, enclosureURL: URL(string: "https://media.example/\($0).mp3")!,
        durationSeconds: 120)
    }
    _ = try await RSSEpisodeStore(database: database).applyRefresh(feedId: feedID, episodes: episodes)
    let rows = try await database.readAsync { db in
      try RSSEpisodeRecord.fetchAll(
        db, sql: "SELECT * FROM rssEpisode WHERE feedId = ?", arguments: [feedID])
    }
    let episodeIDs = Dictionary(
      uniqueKeysWithValues: rows.compactMap { row in row.id.map { (row.identityKey, $0) } })
    return (database, try #require(PodcastSourceIdentity.rss(feedId: feedID)).itemId, episodeIDs)
  }
}

/// Records the ABS progress calls and keeps a minimal projection of what each one wrote, so the
/// source-neutral scenarios can read state back the same way for both sources. Any write naming
/// `ContractHarness.missingEpisodeID` fails, mirroring an RSS episode with no row.
private actor ContractItemProgressIntents: ItemProgressIntents {
  enum Call: Equatable {
    case finish(String, String?, Double?)
    case reset(String, String?)
    case visibility(String, String?, Bool)
    case bulk(String, [String], Bool)
  }

  private(set) var calls: [Call] = []
  private(set) var states: [String: ContractHarness.EpisodeState] = [:]
  private(set) var playerIntentsAtFinish: [PlayerIntent] = []
  private(set) var playerIntentsAtReset: [PlayerIntent] = []
  private let player: FakePlaybackControlling

  init(player: FakePlaybackControlling) {
    self.player = player
  }

  func resetProgress(itemID: String, episodeID: String?) async throws {
    playerIntentsAtReset = player.intents
    try fail(on: [episodeID])
    calls.append(.reset(itemID, episodeID))
    update(episodeID) {
      $0.finished = false
      $0.position = 0
    }
  }

  func resetEbookProgress(itemID: String) async throws {}

  func markAsFinished(itemID: String, episodeID: String?, duration: Double?) async throws {
    playerIntentsAtFinish = player.intents
    try fail(on: [episodeID])
    calls.append(.finish(itemID, episodeID, duration))
    update(episodeID) {
      $0.finished = true
      if let duration { $0.position = duration }
    }
  }

  func setContinueListeningVisibility(
    itemID: String, episodeID: String?, isHidden: Bool
  ) async throws {
    try fail(on: [episodeID])
    calls.append(.visibility(itemID, episodeID, isHidden))
    update(episodeID) { $0.hidden = isHidden }
  }

  func setEpisodesFinished(
    itemID: String, episodes: [EpisodeProgressChange], isFinished: Bool
  ) async throws {
    try fail(on: episodes.map(\.episodeID))
    calls.append(.bulk(itemID, episodes.map(\.episodeID), isFinished))
    for episode in episodes {
      update(episode.episodeID) {
        $0.finished = isFinished
        if isFinished == false { $0.position = 0 }
      }
    }
  }

  private func fail(on episodeIDs: [String?]) throws {
    if episodeIDs.contains(ContractHarness.missingEpisodeID) { throw ContractFailure() }
  }

  private func update(_ episodeID: String?, _ change: (inout ContractHarness.EpisodeState) -> Void) {
    guard let episodeID else { return }
    var state = states[episodeID] ?? ContractHarness.EpisodeState(finished: false, position: 0, hidden: false)
    change(&state)
    states[episodeID] = state
  }
}

extension FakeListeningQueueStoring {
  /// The writes that add to the queue; the other calls are the preparation's reads and removals.
  fileprivate var mutations: [Call] {
    calls.filter {
      switch $0 {
      case .append, .insertNext: true
      default: false
      }
    }
  }
}

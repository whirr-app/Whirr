import Foundation
import Testing
import WatchProtocol

@testable import WatchPlayback

@Suite("Watch received episodes")
struct WatchReceivedEpisodeStoreTests {
  private static let installID = "11111111-1111-4111-8111-111111111111"
  private static let otherInstallID = "22222222-2222-4222-8222-222222222222"

  // MARK: Fixtures

  private func selection(_ feed: String, _ episode: String) throws -> WatchNativeSelection {
    try WatchNativeSelection(feedID: feed, episodeID: episode)
  }

  private func audioURL(_ selection: WatchNativeSelection) -> URL {
    URL(string: "https://cdn.example.test/audio/\(selection.feedID)/\(selection.episodeID).mp3")!
  }

  private func offerEntry(
    _ selection: WatchNativeSelection, revision: UInt64, declaredBytes: Int64? = 40_000_000,
    position: Double = 0, title: String = "Episode", lastListenedAt: Date? = nil,
    chapters: [WatchEpisodeChapter] = []
  ) throws -> WatchEpisodeOfferEntry {
    try WatchEpisodeOfferEntry(
      selection: selection, revision: revision, title: title, showTitle: "Show", duration: 120,
      declaredBytes: declaredBytes, enclosureURL: audioURL(selection), mimeType: "audio/mpeg",
      chapters: chapters, position: position, lastListenedAt: lastListenedAt)
  }

  private func offer(
    generation: UInt64, installID: String? = WatchReceivedEpisodeStoreTests.installID,
    entries: [WatchEpisodeOfferEntry], sentAt: Date
  ) throws -> WatchEpisodeSendOffer {
    try WatchEpisodeSendOffer(
      generation: generation, watchInstallID: installID, entries: entries, sentAt: sentAt)
  }

  private func reservation(_ declaredBytes: Int64?) -> Int64 {
    WatchEnclosureAdmission.reservationBytes(declaredBytes: declaredBytes)
  }

  private func temporaryAudio(bytes: Int, in root: URL) throws -> URL {
    let url = root.appendingPathComponent("incoming-\(UUID().uuidString).tmp")
    try Data(repeating: 0xAB, count: bytes).write(to: url)
    return url
  }

  private func makeStore(
    _ root: URL, stamp: WatchAccountStamp,
    budget: WatchStorageBudget = WatchStorageBudget(), clock: ProgressStoreClock,
    installID: String = WatchReceivedEpisodeStoreTests.installID
  ) throws -> WatchReceivedEpisodeStore {
    try WatchReceivedEpisodeStore(
      rootURL: root.appendingPathComponent("ReceivedEpisodes", isDirectory: true),
      accountStamp: stamp, installID: installID, budget: budget, now: { clock.date })
  }

  private func date(_ seconds: Double) -> Date {
    Date(timeIntervalSinceReferenceDate: seconds)
  }

  /// Offers one episode and downloads it straight away, so a test starts from a ready copy.
  private func offerAndCommit(
    _ store: WatchReceivedEpisodeStore, _ episode: WatchNativeSelection, revision: UInt64 = 1,
    bytes: Int = 4, generation: UInt64, in root: URL
  ) async throws -> WatchReceivedEpisode {
    _ = try await store.apply(
      try offer(
        generation: generation,
        entries: [try offerEntry(episode, revision: revision, declaredBytes: Int64(bytes))],
        sentAt: date(10)))
    let outcome = try await store.commitDownloadedFile(
      selection: episode, revision: revision, temporaryFileURL: try temporaryAudio(bytes: bytes, in: root),
      acceptedBytes: Int64(bytes))
    guard case .committed(let entry) = outcome else {
      throw StoreTestFailure.notCommitted
    }
    return entry
  }

  private enum StoreTestFailure: Error { case notCommitted }

  // MARK: Apply

  @Test("offers for another install or an older generation change nothing")
  func ignoresForeignAndStaleOffers() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let budget = WatchStorageBudget(totalBytes: reservation(10) + 10)
    let store = try makeStore(
      root, stamp: try accountStamp(account: "a", server: "s"), budget: budget,
      clock: ProgressStoreClock(date(10)))
    let episode = try selection("feed", "ep")
    let entry = try offerEntry(episode, revision: 1, declaredBytes: 10)

    let foreign = try offer(
      generation: 1, installID: Self.otherInstallID, entries: [entry], sentAt: date(10))
    let foreignOutcome = try await store.apply(foreign)
    #expect(foreignOutcome == .ignored(.foreignInstall))
    #expect(await store.entries().isEmpty)
    #expect(budget.usedBytes == 0)

    let applied = try offer(generation: 2, installID: Self.installID, entries: [entry], sentAt: date(10))
    let appliedOutcome = try await store.apply(applied)
    #expect(appliedOutcome == .applied(admitted: [episode], declined: [], dropped: []))
    #expect(await store.appliedGeneration == 2)

    let stale = try offer(generation: 2, installID: Self.installID, entries: [], sentAt: date(11))
    let staleOutcome = try await store.apply(stale)
    #expect(staleOutcome == .ignored(.staleGeneration))
    #expect(await store.entries().count == 1)
  }

  @Test("a full shared budget declines without reserving, and a later revision can fit")
  func declinesWhenTheSharedBudgetIsFull() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let budget = WatchStorageBudget(totalBytes: 60_000_000)
    budget.record(20_000_000, for: .audiobookshelf)
    let store = try makeStore(
      root, stamp: try accountStamp(account: "a", server: "s"), budget: budget,
      clock: ProgressStoreClock(date(10)))
    let episode = try selection("feed", "ep")

    let tooLarge = try offer(
      generation: 1, entries: [try offerEntry(episode, revision: 1, declaredBytes: 40_000_000)],
      sentAt: date(10))
    let tooLargeOutcome = try await store.apply(tooLarge)
    #expect(tooLargeOutcome == .applied(admitted: [], declined: [episode], dropped: []))
    let declined = try #require(await store.entry(for: episode))
    #expect(declined.state == .declined)
    #expect(declined.declineReason == .storageFull)
    #expect(declined.committedBytes == nil)
    #expect(await store.reservedBytes() == 0)
    #expect(budget.reservedBytes(for: .receivedEpisodes) == 0)

    let fits = try offer(
      generation: 2, entries: [try offerEntry(episode, revision: 2, declaredBytes: 20_000_000)],
      sentAt: date(11))
    let fitsOutcome = try await store.apply(fits)
    #expect(fitsOutcome == .applied(admitted: [episode], declined: [], dropped: []))
    #expect(await store.entry(for: episode)?.state == .receiving)
    #expect(await store.reservedBytes() == reservation(20_000_000))
    #expect(budget.reservedBytes(for: .receivedEpisodes) == reservation(20_000_000))
  }

  @Test("an unknown declared length reserves the whole cap")
  func unknownLengthReservesTheCap() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let budget = WatchStorageBudget(totalBytes: 3_000_000_000)
    let store = try makeStore(
      root, stamp: try accountStamp(account: "a", server: "s"), budget: budget,
      clock: ProgressStoreClock(date(10)))
    let episode = try selection("feed", "ep")

    _ = try await store.apply(
      try offer(
        generation: 1, entries: [try offerEntry(episode, revision: 1, declaredBytes: nil)],
        sentAt: date(10)))
    #expect(await store.reservedBytes() == WatchEpisodeSendLimits.maxEpisodeBytes)
    #expect(await store.entry(for: episode)?.reservedBytes == WatchEpisodeSendLimits.maxEpisodeBytes)

    // A budget that cannot hold the cap declines the episode rather than overcommitting.
    let small = WatchStorageBudget(totalBytes: 100)
    let smallRoot = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: smallRoot) }
    let smallStore = try makeStore(
      smallRoot, stamp: try accountStamp(account: "a", server: "s"), budget: small,
      clock: ProgressStoreClock(date(10)))
    _ = try await smallStore.apply(
      try offer(
        generation: 1, entries: [try offerEntry(episode, revision: 1, declaredBytes: nil)],
        sentAt: date(10)))
    #expect(await smallStore.entry(for: episode)?.state == .declined)
    #expect(small.usedBytes == 0)
  }

  @Test("an offer that swaps old episodes for new ones on a full Watch admits the new ones")
  func droppedEntriesReleaseTheirBytesBeforeAdmission() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let budget = WatchStorageBudget(totalBytes: reservation(40_000_000))
    let store = try makeStore(
      root, stamp: try accountStamp(account: "a", server: "s"), budget: budget,
      clock: ProgressStoreClock(date(10)))
    let old = try selection("feed", "old")
    let new = try selection("feed", "new")

    let first = try offer(
      generation: 1, entries: [try offerEntry(old, revision: 1, declaredBytes: 40_000_000)],
      sentAt: date(10))
    #expect(try await store.apply(first) == .applied(admitted: [old], declined: [], dropped: []))
    #expect(budget.usedBytes == reservation(40_000_000))

    let swapped = try offer(
      generation: 2, entries: [try offerEntry(new, revision: 1, declaredBytes: 40_000_000)],
      sentAt: date(11))
    #expect(try await store.apply(swapped) == .applied(admitted: [new], declined: [], dropped: []))
    #expect(await store.entry(for: old) == nil)
    #expect(await store.entry(for: new)?.state == .receiving)
    #expect(budget.reservedBytes(for: .receivedEpisodes) == reservation(40_000_000))
  }

  @Test("two unsized episodes overflow 2 GB; the response's length frees room and the decline is taken back")
  func aResponseLengthFreesRoomForADeclinedEpisode() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let budget = WatchStorageBudget(totalBytes: 2_000_000_000)
    let store = try makeStore(
      root, stamp: try accountStamp(account: "a", server: "s"), budget: budget,
      clock: ProgressStoreClock(date(10)))
    let first = try selection("feed", "a")
    let second = try selection("feed", "b")

    let outcome = try await store.apply(
      try offer(
        generation: 1,
        entries: [
          try offerEntry(first, revision: 1, declaredBytes: nil),
          try offerEntry(second, revision: 1, declaredBytes: nil),
        ],
        sentAt: date(10)))
    #expect(outcome == .applied(admitted: [first], declined: [second], dropped: []))
    // Nothing has freed yet, so there is nothing to take back.
    #expect(await store.readmitDeclined() == [])

    let resized = await store.markDownloading(
      selection: first, revision: 1, progress: 0.1, responseBytes: 57_790_052)
    #expect(resized)
    #expect(await store.entry(for: first)?.reservedBytes == reservation(57_790_052))
    #expect(budget.reservedBytes(for: .receivedEpisodes) == reservation(57_790_052))

    #expect(await store.readmitDeclined() == [second])
    let readmitted = try #require(await store.entry(for: second))
    #expect(readmitted.state == .receiving)
    #expect(readmitted.declineReason == nil)
    #expect(await store.pendingDownloads().map(\.selection).contains(second))
    #expect(
      budget.reservedBytes(for: .receivedEpisodes)
        == reservation(57_790_052) + WatchEpisodeSendLimits.maxEpisodeBytes)

    // The resized entry survives a relaunch: its reservation still matches its length.
    let reopened = try makeStore(
      root, stamp: try accountStamp(account: "a", server: "s"), budget: WatchStorageBudget(),
      clock: ProgressStoreClock(date(11)))
    #expect(await reopened.entry(for: first)?.declaredBytes == 57_790_052)
    #expect(await reopened.entry(for: second)?.state == .receiving)
  }

  @Test("a response length that matches, or is no length, changes nothing")
  func anUnhelpfulResponseLengthKeepsTheReservation() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try makeStore(
      root, stamp: try accountStamp(account: "a", server: "s"), clock: ProgressStoreClock(date(10)))
    let episode = try selection("feed", "ep")
    _ = try await store.apply(
      try offer(
        generation: 1, entries: [try offerEntry(episode, revision: 1, declaredBytes: 20_000_000)],
        sentAt: date(10)))
    #expect(
      await store.markDownloading(
        selection: episode, revision: 1, progress: 0.1, responseBytes: 20_000_000) == false)
    #expect(
      await store.markDownloading(selection: episode, revision: 1, progress: 0.2, responseBytes: 0)
        == false)
    #expect(
      await store.markDownloading(
        selection: episode, revision: 1, progress: 0.3,
        responseBytes: WatchEpisodeSendLimits.maxEpisodeBytes + 1) == false)
    #expect(await store.entry(for: episode)?.declaredBytes == 20_000_000)
  }

  @Test("a freed reservation takes back storage-full declines oldest first, and only those that fit")
  func readmissionIsOldestFirstAndOnlyForStorageFull() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let budget = WatchStorageBudget(totalBytes: reservation(40_000_000) * 2)
    let store = try makeStore(
      root, stamp: try accountStamp(account: "a", server: "s"), budget: budget,
      clock: ProgressStoreClock(date(10)))
    let holder = try selection("feed", "holder")
    let older = try selection("feed", "older")
    let newer = try selection("feed", "newer")

    _ = try await store.apply(
      try offer(
        generation: 1,
        entries: [
          try offerEntry(holder, revision: 1),
          try offerEntry(older, revision: 1),
        ],
        sentAt: date(10)))
    _ = try await store.apply(
      try offer(
        generation: 2,
        entries: [
          try offerEntry(holder, revision: 1),
          try offerEntry(older, revision: 1),
          try offerEntry(newer, revision: 1),
        ],
        sentAt: date(20)))
    let newest = try selection("feed", "newest")
    _ = try await store.apply(
      try offer(
        generation: 3,
        entries: [
          try offerEntry(holder, revision: 1),
          try offerEntry(older, revision: 1),
          try offerEntry(newer, revision: 1),
          try offerEntry(newest, revision: 1),
        ],
        sentAt: date(30)))
    #expect(await store.entry(for: newer)?.state == .declined)
    #expect(await store.entry(for: newest)?.state == .declined)
    // Two fill the budget; a failed download frees room for exactly one, the one asked for first.
    await store.markFailed(selection: holder, revision: 1, reason: .network)
    #expect(await store.readmitDeclined() == [newer])
    #expect(await store.entry(for: newest)?.state == .declined)
    #expect(await store.readmitDeclined() == [])
  }

  @Test("a same-revision offer refreshes descriptions and position but keeps the copy")
  func sameRevisionRefreshesWithoutReplacing() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = ProgressStoreClock(date(10))
    let store = try makeStore(root, stamp: try accountStamp(account: "a", server: "s"), clock: clock)
    let episode = try selection("feed", "ep")
    let chapters = [try WatchEpisodeChapter(title: "One", start: 0, end: 30)]
    _ = try await store.apply(
      try offer(
        generation: 1,
        entries: [try offerEntry(episode, revision: 1, declaredBytes: 4, chapters: chapters)],
        sentAt: date(10)))
    _ = try await store.commitDownloadedFile(
      selection: episode, revision: 1, temporaryFileURL: try temporaryAudio(bytes: 4, in: root),
      acceptedBytes: 4)
    let playable = try await store.playableFileURL(for: episode)

    let refresh = try offer(
      generation: 2,
      entries: [
        try offerEntry(
          episode, revision: 1, declaredBytes: 4, position: 12, title: "Renamed",
          lastListenedAt: date(5))
      ], sentAt: date(20))
    let refreshOutcome = try await store.apply(refresh)
    #expect(refreshOutcome == .applied(admitted: [], declined: [], dropped: []))
    let refreshed = try #require(await store.entry(for: episode))
    #expect(refreshed.state == .ready)
    #expect(refreshed.title == "Renamed")
    #expect(refreshed.phonePosition == 12)
    #expect(refreshed.phoneLastListenedAt == date(5))
    #expect(refreshed.chapters == chapters)
    #expect(refreshed.committedBytes == 4)
    #expect(refreshed.offeredAt == date(10))
    let refreshedURL = try await store.playableFileURL(for: episode)
    #expect(refreshedURL == playable)
    #expect(try Data(contentsOf: playable).count == 4)
  }

  @Test("a tombstone survives a repeat offer at the same revision")
  func tombstoneIsNotResurrected() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = ProgressStoreClock(date(10))
    let store = try makeStore(root, stamp: try accountStamp(account: "a", server: "s"), clock: clock)
    let episode = try selection("feed", "ep")
    _ = try await offerAndCommit(store, episode, generation: 1, in: root)
    let playable = try await store.playableFileURL(for: episode)
    let didRemove = try await store.remove(episode)
    #expect(didRemove)
    #expect(FileManager.default.fileExists(atPath: playable.path) == false)
    #expect(await store.reservedBytes() == 0)

    let repeatOffer = try offer(
      generation: 2, entries: [try offerEntry(episode, revision: 1, title: "Again")],
      sentAt: date(11))
    let repeatOutcome = try await store.apply(repeatOffer)
    #expect(repeatOutcome == .applied(admitted: [], declined: [], dropped: []))
    let tombstone = try #require(await store.entry(for: episode))
    #expect(tombstone.state == .removed)
    #expect(tombstone.title == "Again")
    let removedAgain = try await store.remove(episode)
    #expect(removedAgain == false)
  }

  @Test("a higher revision drops the old file and resets the position to the offer's")
  func higherRevisionReplacesAndResetsPosition() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = ProgressStoreClock(date(10))
    let store = try makeStore(root, stamp: try accountStamp(account: "a", server: "s"), clock: clock)
    let episode = try selection("feed", "ep")
    _ = try await offerAndCommit(store, episode, generation: 1, in: root)
    let oldURL = try await store.playableFileURL(for: episode)
    let oldPath = try #require(await store.entry(for: episode)).relativePath

    let resend = try offer(
      generation: 2,
      entries: [try offerEntry(episode, revision: 2, declaredBytes: 8, position: 42)], sentAt: date(11))
    let resendOutcome = try await store.apply(resend)
    #expect(resendOutcome == .applied(admitted: [episode], declined: [], dropped: [episode]))
    let replaced = try #require(await store.entry(for: episode))
    #expect(replaced.state == .receiving)
    #expect(replaced.revision == 2)
    #expect(replaced.phonePosition == 42)
    #expect(replaced.declaredBytes == 8)
    #expect(replaced.reservedBytes == reservation(8))
    #expect(replaced.relativePath != oldPath)
    #expect(FileManager.default.fileExists(atPath: oldURL.path) == false)
    #expect(await store.reservedBytes() == reservation(8))
  }

  @Test("entries absent from the offer are dropped with their files, tombstones included")
  func absentEntriesAreDropped() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = ProgressStoreClock(date(10))
    let budget = WatchStorageBudget()
    let store = try makeStore(
      root, stamp: try accountStamp(account: "a", server: "s"), budget: budget, clock: clock)
    let kept = try selection("feed", "kept")
    let tombstone = try selection("feed", "tombstone")
    _ = try await store.apply(
      try offer(
        generation: 1,
        entries: [
          try offerEntry(kept, revision: 1, declaredBytes: 4),
          try offerEntry(tombstone, revision: 1, declaredBytes: 4),
        ], sentAt: date(10)))
    _ = try await store.commitDownloadedFile(
      selection: kept, revision: 1, temporaryFileURL: try temporaryAudio(bytes: 4, in: root),
      acceptedBytes: 4)
    let keptURL = try await store.playableFileURL(for: kept)
    let didRemove = try await store.remove(tombstone)
    #expect(didRemove)

    let empty = try offer(generation: 2, entries: [], sentAt: date(11))
    let emptyOutcome = try await store.apply(empty)
    #expect(emptyOutcome == .applied(admitted: [], declined: [], dropped: [kept]))
    #expect(await store.entries().isEmpty)
    #expect(FileManager.default.fileExists(atPath: keptURL.path) == false)
    #expect(await store.reservedBytes() == 0)
    #expect(budget.usedBytes == 0)
  }

  // MARK: Download transitions

  @Test("a download moves through downloading, waiting and back, reporting progress")
  func downloadProgressTransitions() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try makeStore(
      root, stamp: try accountStamp(account: "a", server: "s"), clock: ProgressStoreClock(date(10)))
    let episode = try selection("feed", "ep")
    _ = try await store.apply(
      try offer(
        generation: 1, entries: [try offerEntry(episode, revision: 1, declaredBytes: 4)],
        sentAt: date(10)))
    let queued = try #require(await store.entry(for: episode))
    #expect(queued.state == .receiving)
    #expect((await store.pendingDownloads()).map(\.selection) == [episode])

    await store.markDownloading(selection: episode, revision: 1, progress: 0.42)
    var entry = try #require(await store.entry(for: episode))
    #expect(entry.state == .downloading)
    #expect(entry.progress == 0.42)
    #expect(await store.reservedBytes() == queued.reservedBytes)
    #expect((await store.pendingDownloads()).map(\.selection) == [episode])

    // A progress value that is not a fraction is stored as unknown, which is what a server without
    // a length reports.
    await store.markDownloading(selection: episode, revision: 1, progress: 1.5)
    entry = try #require(await store.entry(for: episode))
    #expect(entry.state == .downloading)
    #expect(entry.progress == nil)

    await store.markWaitingForNetwork(selection: episode, revision: 1)
    entry = try #require(await store.entry(for: episode))
    #expect(entry.state == .waitingForNetwork)
    #expect(entry.progress == nil)
    #expect((await store.pendingDownloads()).map(\.selection) == [episode])

    await store.markDownloading(selection: episode, revision: 1, progress: 0.9)
    #expect(await store.entry(for: episode)?.state == .downloading)
  }

  @Test("a transition for another revision is ignored")
  func staleRevisionTransitionsAreIgnored() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try makeStore(
      root, stamp: try accountStamp(account: "a", server: "s"), clock: ProgressStoreClock(date(10)))
    let episode = try selection("feed", "ep")
    _ = try await store.apply(
      try offer(
        generation: 1, entries: [try offerEntry(episode, revision: 2, declaredBytes: 4)],
        sentAt: date(10)))

    await store.markDownloading(selection: episode, revision: 1, progress: 0.5)
    await store.markWaitingForNetwork(selection: episode, revision: 1)
    await store.markFailed(selection: episode, revision: 1, reason: .network)
    let entry = try #require(await store.entry(for: episode))
    #expect(entry.state == .receiving)
    #expect(entry.progress == nil)
    #expect(entry.failureReason == nil)
    #expect(await store.reservedBytes() == reservation(4))

    await store.markDownloading(selection: episode, revision: 3, progress: 0.5)
    #expect(await store.entry(for: episode)?.state == .receiving)
  }

  @Test("a failed download releases its reservation and is re-queued by a higher revision")
  func failureReleasesAndRetryRequeues() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let budget = WatchStorageBudget()
    let store = try makeStore(
      root, stamp: try accountStamp(account: "a", server: "s"), budget: budget,
      clock: ProgressStoreClock(date(10)))
    let episode = try selection("feed", "ep")
    _ = try await store.apply(
      try offer(
        generation: 1, entries: [try offerEntry(episode, revision: 1, declaredBytes: 4)],
        sentAt: date(10)))
    #expect(await store.reservedBytes() == reservation(4))

    await store.markDownloading(selection: episode, revision: 1, progress: 0.5)
    await store.markFailed(selection: episode, revision: 1, reason: .insecureRedirect)
    let failed = try #require(await store.entry(for: episode))
    #expect(failed.state == .failed)
    #expect(failed.failureReason == .insecureRedirect)
    #expect(failed.progress == nil)
    #expect(failed.committedBytes == nil)
    #expect(await store.reservedBytes() == 0)
    #expect(budget.usedBytes == 0)
    #expect(await store.pendingDownloads().isEmpty)

    // "Try Again" is the phone offering the episode at a higher revision.
    _ = try await store.apply(
      try offer(
        generation: 2, entries: [try offerEntry(episode, revision: 2, declaredBytes: 4)],
        sentAt: date(11)))
    let requeued = try #require(await store.entry(for: episode))
    #expect(requeued.state == .receiving)
    #expect(requeued.failureReason == nil)
    #expect(await store.reservedBytes() == reservation(4))
  }

  @Test("a repeat offer at the same revision leaves a failed download failed")
  func sameRevisionDoesNotClearAFailure() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try makeStore(
      root, stamp: try accountStamp(account: "a", server: "s"), clock: ProgressStoreClock(date(10)))
    let episode = try selection("feed", "ep")
    _ = try await store.apply(
      try offer(
        generation: 1, entries: [try offerEntry(episode, revision: 1, declaredBytes: 4)],
        sentAt: date(10)))
    await store.markFailed(selection: episode, revision: 1, reason: .httpStatus)

    _ = try await store.apply(
      try offer(
        generation: 2, entries: [try offerEntry(episode, revision: 1, declaredBytes: 4)],
        sentAt: date(11)))
    let entry = try #require(await store.entry(for: episode))
    #expect(entry.state == .failed)
    #expect(entry.failureReason == .httpStatus)
  }

  @Test("pending downloads keep the store's offer order and omit ready copies")
  func pendingDownloadsInOrder() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try makeStore(
      root, stamp: try accountStamp(account: "a", server: "s"), clock: ProgressStoreClock(date(10)))
    let first = try selection("feed", "a")
    let second = try selection("feed", "b")
    _ = try await store.apply(
      try offer(
        generation: 1,
        entries: [
          try offerEntry(first, revision: 1, declaredBytes: 4),
          try offerEntry(second, revision: 1, declaredBytes: 4),
        ], sentAt: date(10)))
    #expect((await store.pendingDownloads()).map(\.selection) == [first, second])

    _ = try await store.commitDownloadedFile(
      selection: first, revision: 1, temporaryFileURL: try temporaryAudio(bytes: 4, in: root),
      acceptedBytes: 4)
    #expect((await store.pendingDownloads()).map(\.selection) == [second])
  }

  // MARK: Commit

  @Test("every commit outcome consumes the downloaded file")
  func commitOutcomesConsumeTheFile() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try makeStore(
      root, stamp: try accountStamp(account: "a", server: "s"), clock: ProgressStoreClock(date(10)))
    let good = try selection("feed", "good")
    let stale = try selection("feed", "stale")
    let removed = try selection("feed", "removed")
    _ = try await store.apply(
      try offer(
        generation: 1,
        entries: [
          try offerEntry(good, revision: 1, declaredBytes: 4),
          try offerEntry(stale, revision: 2, declaredBytes: 4),
          try offerEntry(removed, revision: 1, declaredBytes: 4),
        ], sentAt: date(10)))
    let didRemove = try await store.remove(removed)
    #expect(didRemove)

    let goodFile = try temporaryAudio(bytes: 4, in: root)
    let committed = try await store.commitDownloadedFile(
      selection: good, revision: 1, temporaryFileURL: goodFile, acceptedBytes: 4)
    guard case .committed(let episode) = committed else {
      Issue.record("expected a committed episode, got \(committed)")
      return
    }
    #expect(episode.state == .ready)
    #expect(episode.committedBytes == 4)
    #expect(FileManager.default.fileExists(atPath: goodFile.path) == false)

    let duplicateFile = try temporaryAudio(bytes: 4, in: root)
    let duplicate = try await store.commitDownloadedFile(
      selection: good, revision: 1, temporaryFileURL: duplicateFile, acceptedBytes: 4)
    #expect(duplicate == .discarded(.duplicate))
    #expect(FileManager.default.fileExists(atPath: duplicateFile.path) == false)

    let staleFile = try temporaryAudio(bytes: 4, in: root)
    let staleOutcome = try await store.commitDownloadedFile(
      selection: stale, revision: 1, temporaryFileURL: staleFile, acceptedBytes: 4)
    #expect(staleOutcome == .discarded(.staleRevision))
    #expect(FileManager.default.fileExists(atPath: staleFile.path) == false)

    let removedFile = try temporaryAudio(bytes: 4, in: root)
    let removedOutcome = try await store.commitDownloadedFile(
      selection: removed, revision: 1, temporaryFileURL: removedFile, acceptedBytes: 4)
    #expect(removedOutcome == .discarded(.removed))
    #expect(FileManager.default.fileExists(atPath: removedFile.path) == false)

    let unknown = try selection("feed", "unknown")
    let unknownFile = try temporaryAudio(bytes: 4, in: root)
    let unknownOutcome = try await store.commitDownloadedFile(
      selection: unknown, revision: 1, temporaryFileURL: unknownFile, acceptedBytes: 4)
    #expect(unknownOutcome == .discarded(.unknown))
    #expect(FileManager.default.fileExists(atPath: unknownFile.path) == false)

    // A declined entry discards the file rather than resurrecting the copy.
    let fullBudget = WatchStorageBudget(totalBytes: 100)
    fullBudget.record(100, for: .audiobookshelf)
    let fullRoot = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: fullRoot) }
    let fullStore = try makeStore(
      fullRoot, stamp: try accountStamp(account: "a", server: "s"), budget: fullBudget,
      clock: ProgressStoreClock(date(10)))
    let declinedSelection = try selection("feed", "declined")
    _ = try await fullStore.apply(
      try offer(
        generation: 1, entries: [try offerEntry(declinedSelection, revision: 1, declaredBytes: 20)],
        sentAt: date(10)))
    #expect(await fullStore.entry(for: declinedSelection)?.state == .declined)
    let declinedFile = try temporaryAudio(bytes: 20, in: fullRoot)
    let declinedOutcome = try await fullStore.commitDownloadedFile(
      selection: declinedSelection, revision: 1, temporaryFileURL: declinedFile, acceptedBytes: 20)
    #expect(declinedOutcome == .discarded(.declined))
    #expect(FileManager.default.fileExists(atPath: declinedFile.path) == false)
  }

  @Test("a commit installs the file, marks the copy ready and shrinks the reservation")
  func commitInstallsTheFile() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = ProgressStoreClock(date(10))
    let budget = WatchStorageBudget()
    let store = try makeStore(
      root, stamp: try accountStamp(account: "a", server: "s"), budget: budget, clock: clock)
    let episode = try selection("feed", "ep")
    let chapters = [
      try WatchEpisodeChapter(title: "One", start: 0, end: 30),
      try WatchEpisodeChapter(title: "Two", start: 30, end: nil),
    ]
    _ = try await store.apply(
      try offer(
        generation: 1,
        entries: [try offerEntry(episode, revision: 1, declaredBytes: 4, chapters: chapters)],
        sentAt: date(10)))
    await store.markDownloading(selection: episode, revision: 1, progress: 0.5)
    #expect(await store.reservedBytes() == reservation(4))

    let file = try temporaryAudio(bytes: 4, in: root)
    let outcome = try await store.commitDownloadedFile(
      selection: episode, revision: 1, temporaryFileURL: file, acceptedBytes: 4)
    guard case .committed(let entry) = outcome else {
      Issue.record("expected a committed episode, got \(outcome)")
      return
    }
    #expect(entry.state == .ready)
    #expect(entry.committedBytes == 4)
    #expect(entry.progress == nil)
    #expect(entry.chapters == chapters)
    #expect(entry.enclosureURL == audioURL(episode))
    #expect(await store.reservedBytes() == 4)
    #expect(budget.reservedBytes(for: .receivedEpisodes) == 4)
    let playable = try await store.playableFileURL(for: episode)
    #expect(try Data(contentsOf: playable).count == 4)
  }

  @Test("a file that does not match the validated byte count fails the entry")
  func sizeMismatchFailsTheEntry() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try makeStore(
      root, stamp: try accountStamp(account: "a", server: "s"), clock: ProgressStoreClock(date(10)))
    let episode = try selection("feed", "ep")
    _ = try await store.apply(
      try offer(
        generation: 1, entries: [try offerEntry(episode, revision: 1, declaredBytes: 4)],
        sentAt: date(10)))

    let shortFile = try temporaryAudio(bytes: 3, in: root)
    let outcome = try await store.commitDownloadedFile(
      selection: episode, revision: 1, temporaryFileURL: shortFile, acceptedBytes: 4)
    #expect(outcome == .discarded(.sizeMismatch))
    #expect(FileManager.default.fileExists(atPath: shortFile.path) == false)
    let entry = try #require(await store.entry(for: episode))
    #expect(entry.state == .failed)
    #expect(entry.failureReason == .invalidResponse)
    #expect(entry.committedBytes == nil)
    #expect(await store.reservedBytes() == 0)
    await #expect(throws: WatchReceivedEpisodeStoreError.notPlayable) {
      try await store.playableFileURL(for: episode)
    }

    // A byte count outside the episode cap is refused without touching the vault.
    let huge = try temporaryAudio(bytes: 4, in: root)
    let hugeOutcome = try await store.commitDownloadedFile(
      selection: episode, revision: 1, temporaryFileURL: huge,
      acceptedBytes: WatchEpisodeSendLimits.maxEpisodeBytes + 1)
    #expect(hugeOutcome == .discarded(.sizeMismatch))
    #expect(FileManager.default.fileExists(atPath: huge.path) == false)
  }

  // MARK: Persistence

  @Test("entries, generation, enclosure fields, chapters and the budget survive a restart")
  func persistenceRoundTrip() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try accountStamp(account: "a", server: "s")
    let clock = ProgressStoreClock(date(10))
    let store = try makeStore(root, stamp: stamp, budget: WatchStorageBudget(), clock: clock)
    let episode = try selection("feed", "ep")
    let chapters = [
      try WatchEpisodeChapter(title: "One", start: 0, end: 30),
      try WatchEpisodeChapter(title: "Two", start: 30, end: nil),
    ]
    _ = try await store.apply(
      try offer(
        generation: 5,
        entries: [try offerEntry(episode, revision: 3, declaredBytes: 4, chapters: chapters)],
        sentAt: date(10)))
    _ = try await store.commitDownloadedFile(
      selection: episode, revision: 3, temporaryFileURL: try temporaryAudio(bytes: 4, in: root),
      acceptedBytes: 4)
    let playable = try await store.playableFileURL(for: episode)

    let restartedBudget = WatchStorageBudget()
    let restarted = try makeStore(root, stamp: stamp, budget: restartedBudget, clock: clock)
    let persisted = try #require(await restarted.entry(for: episode))
    #expect(persisted.state == .ready)
    #expect(persisted.revision == 3)
    #expect(persisted.committedBytes == 4)
    #expect(persisted.declaredBytes == 4)
    #expect(persisted.enclosureURL == audioURL(episode))
    #expect(persisted.chapters == chapters)
    #expect(await restarted.appliedGeneration == 5)
    #expect(await restarted.reservedBytes() == 4)
    #expect(restartedBudget.reservedBytes(for: .receivedEpisodes) == 4)
    let restartedURL = try await restarted.playableFileURL(for: episode)
    #expect(restartedURL == playable)
    #expect(persisted.playbackChapters.last?.end == 120)
  }

  @Test("a download's progress and failure survive a restart")
  func transientStatesPersist() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try accountStamp(account: "a", server: "s")
    let clock = ProgressStoreClock(date(10))
    let store = try makeStore(root, stamp: stamp, budget: WatchStorageBudget(), clock: clock)
    let downloading = try selection("feed", "downloading")
    let failed = try selection("feed", "failed")
    _ = try await store.apply(
      try offer(
        generation: 1,
        entries: [
          try offerEntry(downloading, revision: 1, declaredBytes: 4),
          try offerEntry(failed, revision: 1, declaredBytes: 4),
        ], sentAt: date(10)))
    await store.markDownloading(selection: downloading, revision: 1, progress: 0.42)
    await store.markFailed(selection: failed, revision: 1, reason: .tooLarge)

    let restarted = try makeStore(root, stamp: stamp, budget: WatchStorageBudget(), clock: clock)
    #expect(await restarted.entry(for: downloading)?.state == .downloading)
    #expect(await restarted.entry(for: downloading)?.progress == 0.42)
    #expect(await restarted.entry(for: failed)?.state == .failed)
    #expect(await restarted.entry(for: failed)?.failureReason == .tooLarge)
    #expect(await restarted.pendingDownloads().map(\.selection) == [downloading])
  }

  @Test("another account's payload reads as empty and its files are removed")
  func foreignAccountReadsEmpty() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let clock = ProgressStoreClock(date(10))
    let episode = try selection("feed", "ep")
    let first = try makeStore(
      root, stamp: try accountStamp(account: "b", server: "s"), clock: clock)
    _ = try await offerAndCommit(first, episode, generation: 1, in: root)

    let budget = WatchStorageBudget()
    let second = try makeStore(
      root, stamp: try accountStamp(account: "a", server: "s"), budget: budget, clock: clock)
    #expect(await second.entries().isEmpty)
    #expect(await second.appliedGeneration == 0)
    #expect(budget.usedBytes == 0)
    let files = root.appendingPathComponent("ReceivedEpisodes/files", isDirectory: true)
    #expect((try? FileManager.default.contentsOfDirectory(atPath: files.path))?.isEmpty == true)
  }

  @Test("opening the store deletes files no ready entry references")
  func orphanFilesAreRemovedOnLoad() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try accountStamp(account: "a", server: "s")
    let clock = ProgressStoreClock(date(10))
    let budget = WatchStorageBudget()
    let store = try makeStore(root, stamp: stamp, budget: budget, clock: clock)
    let receiving = try selection("feed", "receiving")
    let ready = try selection("feed", "ready")
    _ = try await store.apply(
      try offer(
        generation: 1,
        entries: [
          try offerEntry(receiving, revision: 1, declaredBytes: 4),
          try offerEntry(ready, revision: 1, declaredBytes: 4),
        ], sentAt: date(10)))
    _ = try await store.commitDownloadedFile(
      selection: ready, revision: 1, temporaryFileURL: try temporaryAudio(bytes: 4, in: root),
      acceptedBytes: 4)
    let readyURL = try await store.playableFileURL(for: ready)
    let receivingPath = try #require(await store.entry(for: receiving)).relativePath
    let files = root.appendingPathComponent("ReceivedEpisodes/files", isDirectory: true)
    let stale = files.appendingPathComponent(receivingPath)
    try Data([1]).write(to: stale)
    let stray = files.appendingPathComponent("stray.mp3")
    try Data([2]).write(to: stray)

    _ = try makeStore(root, stamp: stamp, budget: budget, clock: clock)
    #expect(FileManager.default.fileExists(atPath: stale.path) == false)
    #expect(FileManager.default.fileExists(atPath: stray.path) == false)
    #expect(FileManager.default.fileExists(atPath: readyURL.path))
  }

  @Test("removeAll clears files, the payload and the reservation")
  func removeAllClearsEverything() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let stamp = try accountStamp(account: "a", server: "s")
    let clock = ProgressStoreClock(date(10))
    let budget = WatchStorageBudget()
    let store = try makeStore(root, stamp: stamp, budget: budget, clock: clock)
    let episode = try selection("feed", "ep")
    _ = try await offerAndCommit(store, episode, generation: 1, in: root)
    let playable = try await store.playableFileURL(for: episode)

    try await store.removeAll()
    #expect(await store.entries().isEmpty)
    #expect(await store.appliedGeneration == 0)
    #expect(await store.reservedBytes() == 0)
    #expect(budget.usedBytes == 0)
    #expect(FileManager.default.fileExists(atPath: playable.path) == false)
    let reopened = try makeStore(root, stamp: stamp, budget: budget, clock: clock)
    #expect(await reopened.entries().isEmpty)
  }

  @Test("a failed write leaves every file and the previous memory state intact")
  func failedPersistKeepsFilesAndMemory() async throws {
    #if os(macOS)
      let root = try temporaryDirectory()
      defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
      }
      let stamp = try accountStamp(account: "a", server: "s")
      let clock = ProgressStoreClock(date(10))
      let budget = WatchStorageBudget()
      let store = try makeStore(root, stamp: stamp, budget: budget, clock: clock)
      let episode = try selection("feed", "ep")
      _ = try await offerAndCommit(store, episode, generation: 1, in: root)
      let playable = try await store.playableFileURL(for: episode)

      let storeRoot = root.appendingPathComponent("ReceivedEpisodes", isDirectory: true)
      try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: storeRoot.path)
      await #expect(throws: WatchReceivedEpisodeStoreError.storageFailure) {
        try await store.apply(try offer(generation: 2, entries: [], sentAt: date(11)))
      }
      #expect(await store.entry(for: episode)?.state == .ready)
      #expect(await store.appliedGeneration == 1)
      #expect(await store.reservedBytes() == 4)
      #expect(budget.reservedBytes(for: .receivedEpisodes) == 4)
      #expect(FileManager.default.fileExists(atPath: playable.path))
    #endif
  }
}

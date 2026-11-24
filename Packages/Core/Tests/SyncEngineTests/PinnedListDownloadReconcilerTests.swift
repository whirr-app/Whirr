import Foundation
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

/// The SQL behind every store call is `PinnedListStoreTests`'s job; these pin the reconciler's
/// own decisions.
@Suite struct PinnedListDownloadReconcilerTests {

  @Test func requestsRouteBooksAndEpisodesAndClaimWhatTheyCreated() async {
    let store = FakePinnedListStore()
    store.candidates = [candidate("book-1"), candidate("show", episode: "ep-1")]
    let requests = FakePinnedListRequesting()
    await reconciler(store, requests).run()

    #expect(requests.calls == [.book("book-1"), .episode("show", "ep-1")])
    #expect(store.claims == [claim("book-1"), claim("show", episode: "ep-1")])
  }

  @Test func onePassRequestsAtMostTwenty() async {
    let store = FakePinnedListStore()
    store.candidates = (0..<25).map { candidate("book-\($0)") }
    let requests = FakePinnedListRequesting()
    await reconciler(store, requests).run()

    #expect(requests.calls.count == 20)
    #expect(store.lastCandidateLimit == 20)
  }

  @Test func aThrownRequestIsNotClaimedAndDoesNotStopTheRest() async {
    let store = FakePinnedListStore()
    store.candidates = [candidate("book-1"), candidate("book-2")]
    let requests = FakePinnedListRequesting()
    requests.failing["book-1"] = URLError(.notConnectedToInternet)
    await reconciler(store, requests).run()

    #expect(requests.calls == [.book("book-1"), .book("book-2")])
    #expect(store.claims == [claim("book-2")])
  }

  @Test func aPermanentlyFailingMemberStopsConsumingTheCap() async {
    let store = FakePinnedListStore()
    store.candidates = [candidate("gone")] + (0..<20).map { candidate("book-\($0)") }
    let requests = FakePinnedListRequesting()
    requests.failing["gone"] = DownloadPlanningError.unknownItem("gone")
    let subject = reconciler(store, requests)

    await subject.run()
    requests.calls = []
    await subject.run()

    #expect(requests.calls.contains(.book("gone")) == false)
    #expect(requests.calls.count == 20)
    #expect(store.lastCandidateLimit == 21)
  }

  @Test func aTransientFailureIsTriedAgainNextPass() async {
    let store = FakePinnedListStore()
    store.candidates = [candidate("book-1")]
    let requests = FakePinnedListRequesting()
    requests.failing["book-1"] = URLError(.timedOut)
    let subject = reconciler(store, requests)

    await subject.run()
    await subject.run()

    #expect(requests.calls == [.book("book-1"), .book("book-1")])
  }

  @Test func lowDiskStopsRequestsButStillReleases() async {
    let store = FakePinnedListStore()
    store.candidates = [candidate("book-1")]
    store.releasable = [claim("left")]
    let requests = FakePinnedListRequesting()
    requests.lowDisk = true
    await reconciler(store, requests).run()

    #expect(requests.calls == [.purgeAudio("left")])
  }

  @Test func noPinsDoesNothing() async {
    let store = FakePinnedListStore()
    store.keys = []
    store.candidates = [candidate("book-1")]
    let requests = FakePinnedListRequesting()
    await reconciler(store, requests).run()

    #expect(requests.calls.isEmpty)
    #expect(store.vanishedDrops == 0)
  }

  @Test func everyPassDropsVanishedPinsAndPrunesDeclinesFirst() async {
    let store = FakePinnedListStore()
    await reconciler(store, FakePinnedListRequesting()).run()
    #expect(store.vanishedDrops == 1)
    #expect(store.declinePrunes == 1)
  }

  @Test func releaseDeletesOnlyAudioOfClaimsNothingElseKeeps() async {
    let store = FakePinnedListStore()
    store.releasable = [claim("book-1"), claim("queued"), claim("show", episode: "ep-1")]
    store.kept = [member("queued")]
    let requests = FakePinnedListRequesting()
    await reconciler(store, requests).run()

    #expect(
      requests.calls == [
        .purgeAudio("book-1"), .purgeEpisode("show", "ep-1"),
      ])
    #expect(store.droppedClaims == [claim("book-1"), claim("show", episode: "ep-1")])
  }

  @Test func aReleaseThatThrowsKeepsItsClaim() async {
    let store = FakePinnedListStore()
    store.releasable = [claim("book-1")]
    let requests = FakePinnedListRequesting()
    requests.failing["book-1"] = URLError(.cannotRemoveFile)
    await reconciler(store, requests).run()

    #expect(store.droppedClaims.isEmpty)
  }

  @Test func unpinDeletesClaimsNothingElseKeepsAndCountsTheSameBeforehand() async throws {
    let store = FakePinnedListStore()
    store.claimed = [member("book-1"), member("queued")]
    store.kept = [member("queued")]
    let requests = FakePinnedListRequesting()
    let subject = reconciler(store, requests)

    #expect(try await subject.downloadsUnpinningWouldRemove(key) == 1)
    #expect(store.lastExcluded == key)
    try await subject.unpin(key)

    #expect(store.unpinned == [key])
    #expect(requests.calls == [.purgeAudio("book-1")])
  }

  @Test func pinningRunsAPass() async throws {
    let store = FakePinnedListStore()
    store.keys = []
    store.candidates = [candidate("book-1")]
    let requests = FakePinnedListRequesting()
    try await reconciler(store, requests).pin(key)

    #expect(store.pinned == [key])
    #expect(requests.calls == [.book("book-1")])
  }

  @Test func concurrentRunsShareOnePass() async {
    let store = FakePinnedListStore()
    store.candidates = [candidate("book-1")]
    let requests = FakePinnedListRequesting()
    requests.gate = AsyncGate()
    let subject = reconciler(store, requests)

    async let first: Void = subject.run()
    await requests.gate?.waitUntilEntered()
    async let second: Void = subject.run()
    _ = await awaitCondition("the second run joins the first") { await subject.joinedFlightCount > 0 }
    requests.gate?.open()
    _ = await (first, second)

    #expect(requests.calls == [.book("book-1")])
  }

  // MARK: - Helpers

  private let key = LibraryCollectionKey(serverLibraryID: "books", kind: .playlist, serverID: "pl")

  private func reconciler(
    _ store: FakePinnedListStore, _ requests: FakePinnedListRequesting
  ) -> PinnedListDownloadReconciler {
    PinnedListDownloadReconciler(
      accountID: 1, store: store, requesting: requests, now: { Date(timeIntervalSince1970: 0) })
  }

  private func member(_ item: String, episode: String? = nil) -> PinnedListMember {
    PinnedListMember(serverItemID: item, serverEpisodeID: episode)
  }

  private func candidate(_ item: String, episode: String? = nil) -> PinnedListCandidate {
    PinnedListCandidate(
      key: key, member: member(item, episode: episode), category: episode == nil ? .audiobook : .podcast)
  }

  private func claim(_ item: String, episode: String? = nil) -> PinnedListClaim {
    PinnedListClaim(key: key, member: member(item, episode: episode))
  }
}

/// The first request parks until the test opens the gate. A parked request stays parked through
/// task cancellation, and one that arrives after `open()` passes at once.
final class AsyncGate: @unchecked Sendable {
  private let entries = TestCountRecorder(label: "AsyncGate entries")
  private let gate = TestGate<Void>(label: "AsyncGate request", ignoresCancellation: true)

  init() { gate.hold() }

  func enter() async {
    entries.record()
    await gate.pass()
  }

  func waitUntilEntered() async {
    await entries.waitUntil(count: 1)
  }

  func open() {
    gate.release()
  }
}

final class FakePinnedListRequesting: PinnedListDownloadRequesting, @unchecked Sendable {
  enum Call: Equatable {
    case book(String)
    case episode(String, String)
    case purgeAudio(String)
    case purgeEpisode(String, String)
  }

  private let lock = NSLock()
  private var _calls: [Call] = []
  var calls: [Call] {
    get { lock.withLock { _calls } }
    set { lock.withLock { _calls = newValue } }
  }
  var failing: [String: Error] = [:]
  var lowDisk = false
  var gate: AsyncGate?

  private func record(_ call: Call, item: String) async throws {
    lock.withLock { _calls.append(call) }
    if let gate { await gate.enter() }
    if let error = failing[item] { throw error }
  }

  func requestDownload(itemID: String) async throws {
    try await record(.book(itemID), item: itemID)
  }

  func requestEpisodeDownload(itemID: String, episodeID: String) async throws {
    try await record(.episode(itemID, episodeID), item: itemID)
  }

  func purgeItemAudioDownload(itemID: String, source: DownloadPurgeSource) async throws {
    #expect(source == .pinnedListRelease)
    try await record(.purgeAudio(itemID), item: itemID)
  }

  func purgeEpisodeDownload(itemID: String, episodeID: String, source: DownloadPurgeSource) async throws {
    #expect(source == .pinnedListRelease)
    try await record(.purgeEpisode(itemID, episodeID), item: itemID)
  }

  func isQueuePausedForLowDisk() async -> Bool { lowDisk }
}

final class FakePinnedListStore: PinnedListDownloadStoring, @unchecked Sendable {
  var keys: Set<LibraryCollectionKey> = [
    LibraryCollectionKey(serverLibraryID: "books", kind: .playlist, serverID: "pl")
  ]
  var candidates: [PinnedListCandidate] = []
  var releasable: [PinnedListClaim] = []
  var kept: Set<PinnedListMember> = []
  var claimed: [PinnedListMember] = []
  private(set) var claims: [PinnedListClaim] = []
  private(set) var droppedClaims: [PinnedListClaim] = []
  private(set) var pinned: [LibraryCollectionKey] = []
  private(set) var unpinned: [LibraryCollectionKey] = []
  private(set) var lastCandidateLimit: Int?
  private(set) var lastExcluded: LibraryCollectionKey?
  private(set) var vanishedDrops = 0
  private(set) var declinePrunes = 0

  func pinnedKeys(accountID: Int64) async -> Set<LibraryCollectionKey> { keys }

  func pin(accountID: Int64, key: LibraryCollectionKey, at date: Date) async throws {
    pinned.append(key)
    keys.insert(key)
  }

  func unpin(accountID: Int64, key: LibraryCollectionKey) async throws -> [PinnedListMember] {
    unpinned.append(key)
    keys.remove(key)
    return claimed
  }

  func dropVanishedPins(accountID: Int64) async throws -> Int {
    vanishedDrops += 1
    return 0
  }

  func pruneDeclines(accountID: Int64) async throws { declinePrunes += 1 }

  func candidates(accountID: Int64, limit: Int) async throws -> [PinnedListCandidate] {
    lastCandidateLimit = limit
    return Array(candidates.prefix(limit))
  }

  func recordClaim(
    accountID: Int64, key: LibraryCollectionKey, member: PinnedListMember, at date: Date
  ) async throws {
    claims.append(PinnedListClaim(key: key, member: member))
  }

  func releasableClaims(accountID: Int64) async throws -> [PinnedListClaim] { releasable }

  func dropClaim(accountID: Int64, claim: PinnedListClaim) async throws {
    droppedClaims.append(claim)
  }

  func isKeptBesidesPins(
    accountID: Int64, member: PinnedListMember, excluding: LibraryCollectionKey?
  ) async throws -> Bool {
    lastExcluded = excluding
    return kept.contains(member)
  }

  func claimedMembers(accountID: Int64, key: LibraryCollectionKey) async throws -> [PinnedListMember] {
    claimed
  }
}

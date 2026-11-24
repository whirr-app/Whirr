import Foundation
import Persistence
import TestSupport
import Testing

@testable import SyncEngine

/// The SQL behind every store call is `SmartListDownloadStoreTests`'s job; these pin the
/// reconciler's own decisions against fakes.
@Suite struct SmartListDownloadReconcilerTests {

  // MARK: - Requests and claims

  @Test func requestsEachWantedEpisodeOnceAndClaimsItForEveryListThatWantsIt() async {
    let world = World()
    world.store.wanted = [
      want(1, "rss:1", "e1"), want(2, "rss:1", "e1"), want(1, "show", "s1", .server),
    ]
    await world.reconciler(account: 7).run()

    #expect(world.requests.requested == [.init("rss:1", "e1"), .init("show", "s1")])
    #expect(
      world.store.claims.map(\.listId) == [1, 2, 1]
        && world.store.claims.map(\.itemID) == ["rss:1", "rss:1", "show"])
  }

  @Test func aNativeClaimCarriesNoAccountAndAServerClaimCarriesTheAccountItWasMadeUnder() async {
    let world = World()
    world.store.wanted = [want(1, "rss:1", "e1"), want(1, "show", "s1", .server)]
    await world.reconciler(account: 7).run()

    #expect(world.store.claims.map(\.accountId) == [nil, 7])
  }

  @Test func onlyAnEpisodeWithNoDownloadRowOfAnyOriginIsRequestedOrClaimed() async {
    let world = World()
    world.store.wanted = [want(1, "rss:1", "has-automatic-row"), want(1, "rss:1", "none")]
    world.store.rows = ["rss:1/has-automatic-row"]
    await world.reconciler().run()

    #expect(world.requests.requested == [.init("rss:1", "none")])
    #expect(world.store.claims.map(\.episodeID) == ["none"])
  }

  @Test func theRowCheckHappensAtRequestTimeNotAtSelection() async {
    let world = World()
    world.store.wanted = [want(1, "rss:1", "e1")]
    // Something else downloads it after the wanted set was read and before the request.
    world.store.afterWantedRead = { $0.rows.insert("rss:1/e1") }
    await world.reconciler().run()

    #expect(world.requests.requested.isEmpty)
    #expect(world.store.claims.isEmpty)
  }

  @Test func anEpisodeAnotherListAlreadyClaimsIsSharedNotRequestedAgain() async {
    let world = World()
    world.store.wanted = [want(1, "rss:1", "e1"), want(2, "rss:1", "e1")]
    world.store.rows = ["rss:1/e1"]
    world.store.claims = [claim(1, "rss:1", "e1")]
    await world.reconciler().run()

    #expect(world.requests.requested.isEmpty)
    #expect(world.store.claims.map(\.listId) == [1, 2])
  }

  @Test func onePassRequestsAtMostTwentyAndTheNextPassFillsTheRest() async {
    let world = World()
    world.store.wanted = (0..<25).map { want(1, "rss:1", "e\($0)") }
    let subject = world.reconciler()

    await subject.run()
    #expect(world.requests.requested.count == 20)
    await subject.run()
    #expect(world.requests.requested.count == 25)
    #expect(world.store.claims.count == 25)
  }

  @Test func anAudiobookshelfEpisodeMissingItsStoredFileIsRefusedOnceForTheProcess() async {
    let world = World()
    world.store.wanted = [want(1, "show", "no-ino", .server), want(1, "show", "ok", .server)]
    world.requests.failing["no-ino"] = DownloadPlanningError.episodeUnavailable
    let subject = world.reconciler(account: 1)

    await subject.run()
    await subject.run()

    #expect(world.requests.requested.filter { $0.episode == "no-ino" }.count == 1)
    #expect(world.store.claims.map(\.episodeID) == ["ok"])
  }

  @Test func aTransientFailureIsNotClaimedAndIsTriedAgainNextPass() async {
    let world = World()
    world.store.wanted = [want(1, "rss:1", "e1"), want(1, "rss:1", "e2")]
    world.requests.failing["e1"] = URLError(.timedOut)
    let subject = world.reconciler()

    await subject.run()
    #expect(world.store.claims.map(\.episodeID) == ["e2"])
    world.requests.failing = [:]
    await subject.run()

    #expect(world.requests.requested.filter { $0.episode == "e1" }.count == 2)
    #expect(Set(world.store.claims.map(\.episodeID)) == ["e1", "e2"])
  }

  @Test func requestsAreAlwaysTheOrdinaryRequestSoTheReaperNeverSeesThemAsAutomatic() async {
    // `SmartListDownloadRequesting` offers no `requestAutomaticEpisodeDownload`, and a `.manual`
    // row is outside `PodcastAutoDownloadReapStore`'s candidates (`manualDownloadIsNeverReaped`).
    let world = World()
    world.store.wanted = [want(1, "rss:1", "e1")]
    await world.reconciler().run()
    #expect(world.requests.requested == [.init("rss:1", "e1")])
  }

  // MARK: - Hand removals

  @Test func anEpisodeRemovedByHandIsNotDownloadedAgainOnTheNextPass() async {
    let world = World()
    world.store.wanted = [want(1, "rss:1", "e1"), want(1, "rss:1", "e2")]
    let subject = world.reconciler()
    await subject.run()
    #expect(world.requests.requested == [.init("rss:1", "e1"), .init("rss:1", "e2")])

    // What `SmartListDecliningDownloadIntents` leaves after a hand purge: the row gone, the
    // episode declined, its claims dropped.
    world.store.rows.remove("rss:1/e1")
    world.store.declined = ["rss:1/e1"]
    world.store.claims.removeAll { $0.episodeID == "e1" }
    await subject.run()

    #expect(world.requests.requested.filter { $0.episode == "e1" }.count == 1)
    #expect(world.store.claims.map(\.episodeID) == ["e2"])
    #expect(world.requests.purged.isEmpty)
  }

  @Test func aDeclinedEpisodeIsNotClaimedBySharingAnotherDownload() async {
    let world = World()
    world.store.wanted = [want(1, "rss:1", "e1"), want(2, "rss:1", "e1")]
    world.store.rows = ["rss:1/e1"]
    world.store.claims = [claim(1, "rss:1", "e1")]
    world.store.declined = ["rss:1/e1"]
    await world.reconciler().run()

    #expect(world.requests.requested.isEmpty)
    #expect(world.store.claims.map(\.listId) == [1])
  }

  @Test func aDeclineWrittenAfterTheWantedSetWasReadStillStopsTheRequest() async {
    let world = World()
    world.store.wanted = [want(1, "rss:1", "e1")]
    world.store.afterWantedRead = { $0.declined.insert("rss:1/e1") }
    await world.reconciler().run()

    #expect(world.requests.requested.isEmpty)
    #expect(world.store.claims.isEmpty)
  }

  @Test func aClearedDeclineIsRequestedOnTheNextPass() async {
    let world = World()
    world.store.wanted = [want(1, "rss:1", "e1")]
    world.store.declined = ["rss:1/e1"]
    let subject = world.reconciler()
    await subject.run()
    #expect(world.requests.requested.isEmpty)

    world.store.declined = []
    await subject.run()
    #expect(world.requests.requested == [.init("rss:1", "e1")])
  }

  @Test func declinesArePrunedOnEveryPassWithWork() async {
    let world = World()
    world.store.wanted = [want(1, "rss:1", "e1")]
    let subject = world.reconciler()
    await subject.run()
    await subject.run()
    #expect(world.store.declinePrunes == 2)
  }

  // MARK: - Signed out

  @Test func signedOutItRequestsNativeEpisodesOnlyAndLeavesServerClaimsAlone() async {
    let world = World()
    world.store.wanted = [want(1, "rss:1", "e1"), want(1, "show", "s1", .server)]
    world.store.claims = [claim(1, "show", "old", account: 3)]
    await world.reconciler(account: nil).run()

    #expect(world.requests.requested == [.init("rss:1", "e1")])
    #expect(world.requests.purged.isEmpty)
    #expect(world.store.claims.contains { $0.itemID == "show" && $0.episodeID == "old" })
    #expect(world.store.claims.contains { $0.episodeID == "e1" && $0.accountId == nil })
  }

  // MARK: - Release

  @Test func aClaimThatLeftTheWantedSetIsDroppedAndItsDownloadPurgedAsASmartListRelease() async {
    let world = World()
    world.store.claims = [claim(1, "rss:1", "gone"), claim(1, "show", "s-gone", account: 1)]
    await world.reconciler(account: 1).run()

    #expect(
      world.requests.purged == [.init("rss:1", "gone", .smartListRelease), .init("show", "s-gone", .smartListRelease)])
    #expect(world.store.claims.isEmpty)
  }

  @Test func aReleaseKeptByQueueSavedPinPlaybackOrATransferDropsTheClaimButDeletesNothing() async {
    let world = World()
    world.store.claims = [claim(1, "rss:1", "kept"), claim(1, "rss:1", "free")]
    world.store.kept = ["rss:1/kept"]
    await world.reconciler().run()

    #expect(world.requests.purged == [.init("rss:1", "free", .smartListRelease)])
    #expect(world.store.claims.isEmpty)
  }

  @Test func anEpisodeTwoListsClaimIsPurgedOnlyWhenTheLastClaimGoes() async {
    let world = World()
    world.store.claims = [claim(1, "rss:1", "shared"), claim(2, "rss:1", "shared")]
    world.store.wanted = [want(2, "rss:1", "shared")]
    world.store.rows = ["rss:1/shared"]
    let subject = world.reconciler()

    await subject.run()
    #expect(world.requests.purged.isEmpty)
    #expect(world.store.claims.map(\.listId) == [2])

    world.store.wanted = []
    await subject.run()
    #expect(world.requests.purged == [.init("rss:1", "shared", .smartListRelease)])
    #expect(world.store.claims.isEmpty)
  }

  @Test func whenBothListsLetGoInOnePassTheDownloadIsPurgedOnce() async {
    let world = World()
    world.store.claims = [claim(1, "rss:1", "shared"), claim(2, "rss:1", "shared")]
    await world.reconciler().run()

    #expect(world.requests.purged == [.init("rss:1", "shared", .smartListRelease)])
    #expect(world.store.claims.isEmpty)
  }

  @Test func aFailedPurgeKeepsTheClaimForTheNextPass() async {
    let world = World()
    world.store.claims = [claim(1, "rss:1", "e1")]
    world.requests.failing["e1"] = URLError(.cannotRemoveFile)
    let subject = world.reconciler()

    await subject.run()
    #expect(world.store.claims.count == 1)
    world.requests.failing = [:]
    await subject.run()
    #expect(world.store.claims.isEmpty)
  }

  @Test func aRowAlreadyRemovedByDeleteAfterPlayingIsReleasedAsANoOp() async {
    // The coordinator treats a missing row as done: the purge returns without throwing.
    let world = World()
    world.store.claims = [claim(1, "show", "finished", account: 1)]
    world.store.rows = []
    await world.reconciler(account: 1).run()

    #expect(world.store.claims.isEmpty)
    #expect(world.requests.purged.count == 1)
  }

  @Test func switchingAutoDownloadOffReleasesEveryClaimOfThatList() async {
    let world = World()
    world.store.claims = [claim(1, "rss:1", "e1"), claim(1, "rss:1", "e2"), claim(2, "rss:1", "e3")]
    world.store.wanted = [want(2, "rss:1", "e3")]
    world.store.rows = ["rss:1/e3"]
    await world.reconciler().run()

    #expect(world.requests.purged.map(\.episode) == ["e1", "e2"])
    #expect(world.store.claims.map(\.episodeID) == ["e3"])
  }

  @Test func aFailedWantedReadReleasesNothing() async {
    let world = World()
    world.store.claims = [claim(1, "rss:1", "e1")]
    world.store.wantedFails = true
    await world.reconciler().run()

    #expect(world.requests.purged.isEmpty)
    #expect(world.store.claims.count == 1)
  }

  @Test func deletingAListDeletesItThenReleasesItsDownloads() async throws {
    let world = World()
    world.store.claims = [claim(1, "rss:1", "e1"), claim(2, "rss:1", "other")]
    try await world.reconciler().deleteList(1)

    #expect(world.store.events == ["claims", "deleteList:1", "hasClaim", "kept"])
    #expect(world.requests.purged == [.init("rss:1", "e1", .smartListRelease)])
    #expect(world.store.claims.map(\.listId) == [2])
  }

  /// A list the user asked to delete goes, whatever its downloads do: a release that fails leaves
  /// a file behind, which is recoverable, where a list that will not delete is not.
  @Test func aListWhoseReleaseFailsIsStillDeleted() async throws {
    let world = World()
    world.store.claims = [claim(1, "rss:1", "e1"), claim(1, "rss:1", "e2")]
    world.requests.failing["e1"] = URLError(.cannotRemoveFile)

    try await world.reconciler().deleteList(1)
    #expect(world.store.deletedLists == [1])
    #expect(world.requests.purged.map(\.episode) == ["e1", "e2"])
  }

  /// Another list's claim on the same episode keeps the file.
  @Test func deletingAListKeepsAnEpisodeAnotherListClaims() async throws {
    let world = World()
    world.store.claims = [claim(1, "rss:1", "e1"), claim(2, "rss:1", "e1")]
    try await world.reconciler().deleteList(1)

    #expect(world.requests.purged.isEmpty)
    #expect(world.store.claims.map(\.listId) == [2])
  }

  // MARK: - Gates

  @Test func lowPowerModeRefusesTheWholePassButStillReleases() async {
    let world = World()
    world.network.isLowPowerMode = true
    world.store.wanted = [want(1, "rss:1", "e1")]
    world.store.claims = [claim(1, "rss:1", "left")]
    await world.reconciler().run()

    #expect(world.requests.requested.isEmpty)
    #expect(world.requests.purged.count == 1)
  }

  @Test func onCellularEachHalfFollowsItsOwnAllowCellularSetting() async {
    let world = World()
    world.network.isConstrainedOrCellular = true
    world.store.wanted = [want(1, "rss:1", "n1"), want(1, "show", "s1", .server)]

    await world.reconciler(account: 1, nativeCellular: true, serverCellular: false).run()
    #expect(world.requests.requested == [.init("rss:1", "n1")])

    let other = World()
    other.network.isConstrainedOrCellular = true
    other.store.wanted = world.store.wanted
    await other.reconciler(account: 1, nativeCellular: false, serverCellular: true).run()
    #expect(other.requests.requested == [.init("show", "s1")])
  }

  @Test func onCellularWithNeitherSettingAPassRequestsNothing() async {
    let world = World()
    world.network.isConstrainedOrCellular = true
    world.store.wanted = [want(1, "rss:1", "n1"), want(1, "show", "s1", .server)]
    await world.reconciler(account: 1).run()

    #expect(world.requests.requested.isEmpty)
    #expect(world.store.claims.isEmpty)
  }

  @Test func onWiFiBothHalvesAreAdmittedWhateverTheCellularSettings() async {
    let world = World()
    world.store.wanted = [want(1, "rss:1", "n1"), want(1, "show", "s1", .server)]
    await world.reconciler(account: 1).run()
    #expect(world.requests.requested.count == 2)
  }

  @Test func lowDiskStopsRequestsButStillReleases() async {
    let world = World()
    world.requests.lowDisk = true
    world.store.wanted = [want(1, "rss:1", "e1")]
    world.store.claims = [claim(1, "rss:1", "left")]
    await world.reconciler().run()

    #expect(world.requests.requested.isEmpty)
    #expect(world.requests.purged.map(\.episode) == ["left"])
  }

  @Test func everyPassPrunesFinishedOrGoneHiddenRows() async {
    let world = World()
    world.store.wanted = [want(1, "rss:1", "e1")]
    await world.reconciler().run()
    #expect(world.store.prunes == 1)
  }

  // MARK: - Triggers

  @Test func concurrentRunsShareOnePass() async {
    let world = World()
    world.store.wanted = [want(1, "rss:1", "e1")]
    world.requests.gate = AsyncGate()
    let subject = world.reconciler()

    async let first: Void = subject.run()
    await world.requests.gate?.waitUntilEntered()
    async let second: Void = subject.run()
    _ = await awaitCondition("the second run joins the first") { await subject.joinedFlightCount > 0 }
    world.requests.gate?.open()
    _ = await (first, second)

    #expect(world.requests.requested.count == 1)
  }

  @Test func aBurstOfWantedSetChangesRunsOnePassAfterTheDebounce() async {
    let world = World()
    world.store.wanted = [want(1, "rss:1", "e1")]
    let subject = world.reconciler()
    let (stream, continuation) = AsyncStream.makeStream(of: [SmartListWantedEpisode.Key].self)
    let observer = Task { await subject.runOnChanges(stream, debounce: .milliseconds(150)) }

    for _ in 0..<5 { continuation.yield([]) }
    _ = await awaitCondition("the debounced pass ran") { world.requests.requested.count == 1 }
    // Stable for longer than the debounce, so a second debounced pass would have shown.
    _ = await awaitQuiescence("no second pass", stableFor: 300) { "\(world.store.wantedReads)" }
    #expect(world.store.wantedReads == 1)

    continuation.finish()
    await observer.value
  }

  // MARK: - Helpers

  private func want(
    _ list: Int64, _ item: String, _ episode: String, _ source: SmartListShowSource = .native
  ) -> SmartListWantedEpisode {
    SmartListWantedEpisode(listID: list, source: source, itemID: item, episodeID: episode)
  }

  private func claim(_ list: Int64, _ item: String, _ episode: String, account: Int64? = nil)
    -> SmartListDownloadClaimRecord
  {
    SmartListDownloadClaimRecord(
      listId: list, itemID: item, episodeID: episode, accountId: account,
      claimedAt: Date(timeIntervalSince1970: 0))
  }
}

// MARK: - World

private struct World {
  let store = FakeSmartListDownloadStore()
  let requests = FakeSmartListRequesting()
  let network = FakeNetworkConditions()

  func reconciler(
    account: Int64? = nil, nativeCellular: Bool = false, serverCellular: Bool = false
  ) -> SmartListDownloadReconciler {
    store.requests = requests
    requests.store = store
    return SmartListDownloadReconciler(
      accountID: account, store: store, requesting: requests, networkConditions: network,
      nativeSettings: Self.cellularSettings(allow: nativeCellular),
      serverSettings: Self.cellularSettings(allow: serverCellular),
      now: { Date(timeIntervalSince1970: 0) })
  }

  private static func cellularSettings(allow: Bool) -> FakePodcastSettingsReading {
    FakePodcastSettingsReading(
      global: PodcastGlobalSettings(
        autoDownloadEnabled: true, keepLatestCount: 3, deleteAfterPlayed: false,
        allowCellularAutoDownload: allow, enabledAt: nil))
  }
}

private final class FakeSmartListDownloadStore: SmartListDownloadStoring, @unchecked Sendable {
  private let lock = NSLock()
  weak var requests: FakeSmartListRequesting?
  private var _wanted: [SmartListWantedEpisode] = []
  private var _claims: [SmartListDownloadClaimRecord] = []
  private var _rows: Set<String> = []
  private var _kept: Set<String> = []
  private var _events: [String] = []
  private var _deleted: [Int64] = []
  private var _prunes = 0
  private var _declinePrunes = 0
  private var _declined: Set<String> = []
  private var _wantedReads = 0
  var wantedFails = false
  var afterWantedRead: (@Sendable (FakeSmartListDownloadStore) -> Void)?

  var wanted: [SmartListWantedEpisode] {
    get { lock.withLock { _wanted } }
    set { lock.withLock { _wanted = newValue } }
  }
  var claims: [SmartListDownloadClaimRecord] {
    get { lock.withLock { _claims } }
    set { lock.withLock { _claims = newValue } }
  }
  var rows: Set<String> {
    get { lock.withLock { _rows } }
    set { lock.withLock { _rows = newValue } }
  }
  var kept: Set<String> {
    get { lock.withLock { _kept } }
    set { lock.withLock { _kept = newValue } }
  }
  /// `item/episode` keys a hand removal declined.
  var declined: Set<String> {
    get { lock.withLock { _declined } }
    set { lock.withLock { _declined = newValue } }
  }
  var declinePrunes: Int { lock.withLock { _declinePrunes } }
  var events: [String] { lock.withLock { _events } }
  var deletedLists: [Int64] { lock.withLock { _deleted } }
  var prunes: Int { lock.withLock { _prunes } }
  var wantedReads: Int { lock.withLock { _wantedReads } }

  func addRow(_ key: String) { lock.withLock { _ = _rows.insert(key) } }

  func wantedEpisodes() async throws -> [SmartListWantedEpisode] {
    if wantedFails { throw URLError(.unknown) }
    lock.withLock { _wantedReads += 1 }
    let result = wanted
    afterWantedRead?(self)
    return result
  }

  func claims() async throws -> [SmartListDownloadClaimRecord] {
    lock.withLock { _events.append("claims") }
    return claims
  }

  func recordClaim(
    listID: Int64, itemID: String, episodeID: String, accountID: Int64?, at date: Date
  ) async throws {
    lock.withLock {
      guard
        _claims.contains(where: { $0.listId == listID && $0.itemID == itemID && $0.episodeID == episodeID })
          == false
      else { return }
      _claims.append(
        SmartListDownloadClaimRecord(
          listId: listID, itemID: itemID, episodeID: episodeID, accountId: accountID, claimedAt: date))
    }
  }

  func dropClaim(listID: Int64, itemID: String, episodeID: String) async throws {
    lock.withLock {
      _events.append("dropClaim")
      _claims.removeAll { $0.listId == listID && $0.itemID == itemID && $0.episodeID == episodeID }
    }
  }

  func hasClaim(itemID: String, episodeID: String, excluding listID: Int64?) async throws -> Bool {
    lock.withLock {
      _events.append("hasClaim")
      return _claims.contains {
        $0.itemID == itemID && $0.episodeID == episodeID && $0.listId != listID
      }
    }
  }

  func requestState(itemID: String, episodeID: String, accountID: Int64?) async throws
    -> SmartListRequestState
  {
    lock.withLock {
      let key = "\(itemID)/\(episodeID)"
      if _declined.contains(key) { return .declined }
      return _rows.contains(key) ? .hasDownloadRow : .requestable
    }
  }

  func isKeptBesidesClaims(itemID: String, episodeID: String, accountID: Int64?) async throws -> Bool {
    lock.withLock {
      _events.append("kept")
      return _kept.contains("\(itemID)/\(episodeID)")
    }
  }

  func deleteList(id: Int64) async throws {
    lock.withLock {
      _events.append("deleteList:\(id)")
      _deleted.append(id)
      _claims.removeAll { $0.listId == id }
    }
  }

  func pruneHiddenEpisodes() async throws -> Int {
    lock.withLock { _prunes += 1 }
    return 0
  }

  func pruneDeclines() async throws -> Int {
    lock.withLock { _declinePrunes += 1 }
    return 0
  }
}

private final class FakeSmartListRequesting: SmartListDownloadRequesting, @unchecked Sendable {
  struct Call: Equatable {
    let item: String
    let episode: String
    let source: DownloadPurgeSource?

    init(_ item: String, _ episode: String, _ source: DownloadPurgeSource? = nil) {
      self.item = item
      self.episode = episode
      self.source = source
    }
  }

  weak var store: FakeSmartListDownloadStore?
  private let lock = NSLock()
  private var _requested: [Call] = []
  private var _purged: [Call] = []
  var failing: [String: Error] = [:]
  var lowDisk = false
  var gate: AsyncGate?

  var requested: [Call] { lock.withLock { _requested } }
  var purged: [Call] { lock.withLock { _purged } }

  func requestEpisodeDownload(itemID: String, episodeID: String) async throws {
    lock.withLock { _requested.append(Call(itemID, episodeID)) }
    if let gate { await gate.enter() }
    if let error = failing[episodeID] { throw error }
    store?.addRow("\(itemID)/\(episodeID)")
  }

  func purgeEpisodeDownload(itemID: String, episodeID: String, source: DownloadPurgeSource) async throws {
    lock.withLock { _purged.append(Call(itemID, episodeID, source)) }
    if let error = failing[episodeID] { throw error }
  }

  func isQueuePausedForLowDisk() async -> Bool { lowDisk }
}

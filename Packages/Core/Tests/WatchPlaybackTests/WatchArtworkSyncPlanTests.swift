import Foundation
import Testing
import WatchProtocol

@testable import WatchPlayback

struct WatchArtworkSyncPlanTests {
  let phone = try! WatchAccountStamp(accountIdentityHash: "phone", serverIdentityHash: "s")
  let watch = try! WatchAccountStamp(accountIdentityHash: "watch", serverIdentityHash: "s")
  let other = try! WatchAccountStamp(accountIdentityHash: "other", serverIdentityHash: "s")
  let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

  func cover(_ id: String) -> WatchArtworkCover {
    WatchArtworkCover(reference: WatchArtworkReference(source: .audiobookshelf(itemID: id), revision: "1"), size: .row)
  }

  func manifest(_ ids: [String], stamp: WatchAccountStamp? = nil, authenticated: WatchAccountStamp? = nil) throws
    -> WatchArtworkManifest
  {
    try WatchArtworkManifest(
      accountStamp: stamp ?? phone, authenticatedAccountStamp: authenticated, covers: ids.map(cover))
  }

  @Test func withNoManifestItAsksForOneOnceADay() throws {
    var plan = WatchArtworkSyncPlan()
    let result1 = plan.nextRequest(currentPhoneStamp: phone, synced: [], now: start)
    let ask = try #require(result1)
    #expect(ask.isManifestRequest)
    #expect(ask.accountStamp == phone)
    let result2 = plan.nextRequest(currentPhoneStamp: phone, synced: [], now: start.addingTimeInterval(60))
    #expect(result2 == nil)
    let again = plan.nextRequest(currentPhoneStamp: phone, synced: [], now: start.addingTimeInterval(86_401))
    #expect(again?.isManifestRequest == true)
    let result3 = plan.nextRequest(currentPhoneStamp: nil, synced: [], now: start)
    #expect(result3 == nil)
  }

  @Test func aNewPhoneAccountAsksAtOnceAndForgetsTheOldManifest() throws {
    var plan = WatchArtworkSyncPlan()
    _ = plan.receive(try manifest(["a"]), currentPhoneStamp: phone, synced: [])
    let result4 = plan.nextRequest(currentPhoneStamp: other, synced: [], now: start)
    let ask = try #require(result4)
    #expect(ask.isManifestRequest)
    #expect(ask.accountStamp == other)
    #expect(plan.manifest == nil)
  }

  @Test func rejectsAManifestOrBundleForAnotherAccount() throws {
    var plan = WatchArtworkSyncPlan()
    let result5 = plan.receive(try manifest(["a"], stamp: other), currentPhoneStamp: phone, synced: [])
    #expect(result5 == .rejected)
    let result6 = plan.receive(try manifest(["a"]), currentPhoneStamp: nil, synced: [])
    #expect(result6 == .rejected)
    #expect(plan.manifest == nil)
    _ = plan.receive(try manifest(["a"]), currentPhoneStamp: phone, synced: [])
    let foreignList = try WatchArtworkWantList(accountStamp: other, manifestID: nil, covers: [])
    let bundle = try WatchArtworkBundle(
      answering: foreignList, entries: [.init(cover: cover("a"), imageData: Data([1]))], unavailable: [],
      isFinal: true)
    let result7 = plan.receive(bundle, currentPhoneStamp: phone)
    #expect(result7 == nil)
  }

  @Test func acceptingAManifestPrunesSyncedCoversItNoLongerLists() throws {
    var plan = WatchArtworkSyncPlan()
    let outcome = plan.receive(
      try manifest(["a", "b"]), currentPhoneStamp: phone, synced: [cover("a"), cover("gone")])
    #expect(outcome == .accepted(prune: [cover("gone")]))
  }

  @Test func asksForMissingCoversInManifestOrderInBoundedBatches() throws {
    var plan = WatchArtworkSyncPlan()
    let ids = (0..<300).map { "item\($0)" }
    let next = try manifest(ids)
    _ = plan.receive(next, currentPhoneStamp: phone, synced: [])
    let result8 = plan.nextRequest(currentPhoneStamp: phone, synced: [cover("item0")], now: start)
    let first = try #require(result8)
    #expect(first.manifestID == next.id)
    #expect(first.covers.count == WatchArtworkSyncLimits.maxWantedCovers)
    #expect(first.covers.first == cover("item1"))
    let result9 = plan.nextRequest(currentPhoneStamp: phone, synced: [], now: start)
    #expect(result9 == nil, "one want list at a time")

    let answered = try WatchArtworkBundle(
      answering: first, entries: first.covers.prefix(2).map { .init(cover: $0, imageData: Data([1])) },
      unavailable: Array(first.covers.dropFirst(2)), isFinal: true)
    let result10 = plan.receive(answered, currentPhoneStamp: phone)
    let entries = try #require(result10)
    #expect(entries.count == 2)
    #expect(plan.outstanding == nil)
    let synced = Set([cover("item0")] + entries.map(\.cover))
    let result11 = plan.nextRequest(currentPhoneStamp: phone, synced: synced, now: start)
    let second = try #require(result11)
    #expect(second.covers == Array(next.covers.suffix(300 - 1 - 256)))
  }

  @Test func aCompleteLibraryAsksForNothing() throws {
    var plan = WatchArtworkSyncPlan()
    _ = plan.receive(try manifest(["a"]), currentPhoneStamp: phone, synced: [])
    let result12 = plan.nextRequest(currentPhoneStamp: phone, synced: [cover("a")], now: start)
    #expect(result12 == nil)
  }

  @Test func anUnansweredWantListIsSentAgainAfterADay() throws {
    var plan = WatchArtworkSyncPlan()
    _ = plan.receive(try manifest(["a"]), currentPhoneStamp: phone, synced: [])
    let result13 = plan.nextRequest(currentPhoneStamp: phone, synced: [], now: start)
    let first = try #require(result13)
    let result14 = plan.nextRequest(currentPhoneStamp: phone, synced: [], now: start.addingTimeInterval(3600))
    #expect(result14 == nil)
    let result15 = plan.nextRequest(currentPhoneStamp: phone, synced: [], now: start.addingTimeInterval(86_401))
    let retry = try #require(result15)
    #expect(retry.covers == first.covers)
    #expect(retry.id != first.id)
  }

  /// The phone drops a want list that arrives before its app binds the account, then sends a
  /// manifest when it binds. That manifest is the sign to ask again, not a day later.
  @Test func aResentManifestWithTheSameCoversAsksAgainAtOnce() throws {
    var plan = WatchArtworkSyncPlan()
    _ = plan.receive(try manifest(["a", "b"]), currentPhoneStamp: phone, synced: [])
    let result = plan.nextRequest(currentPhoneStamp: phone, synced: [], now: start)
    let first = try #require(result)
    let unavailable = try WatchArtworkBundle(
      answering: first, entries: [], unavailable: [cover("b")], isFinal: false)
    _ = plan.receive(unavailable, currentPhoneStamp: phone)

    _ = plan.receive(try manifest(["a", "b"]), currentPhoneStamp: phone, synced: [])
    let retried = plan.nextRequest(currentPhoneStamp: phone, synced: [], now: start.addingTimeInterval(60))
    let retry = try #require(retried)
    #expect(retry.id != first.id)
    #expect(retry.covers == [cover("a")])
  }

  @Test func aNonFinalBundleKeepsTheWantListOutstanding() throws {
    var plan = WatchArtworkSyncPlan()
    _ = plan.receive(try manifest(["a", "b"]), currentPhoneStamp: phone, synced: [])
    let result16 = plan.nextRequest(currentPhoneStamp: phone, synced: [], now: start)
    let wants = try #require(result16)
    let partial = try WatchArtworkBundle(
      answering: wants, entries: [.init(cover: cover("a"), imageData: Data([1]))], unavailable: [], isFinal: false)
    _ = plan.receive(partial, currentPhoneStamp: phone)
    #expect(plan.outstanding?.id == wants.id)
  }

  @Test func bundleEntriesTheManifestDoesNotListAreDropped() throws {
    var plan = WatchArtworkSyncPlan()
    _ = plan.receive(try manifest(["a"]), currentPhoneStamp: phone, synced: [])
    let wants = try WatchArtworkWantList(accountStamp: phone, manifestID: nil, covers: [])
    let bundle = try WatchArtworkBundle(
      answering: wants,
      entries: [.init(cover: cover("a"), imageData: Data([1])), .init(cover: cover("stray"), imageData: Data([1]))],
      unavailable: [cover("stray")], isFinal: true)
    let result17 = plan.receive(bundle, currentPhoneStamp: phone)
    #expect(result17?.map(\.cover) == [cover("a")])
    #expect(plan.unavailable.isEmpty)
  }

  @Test func aChangedManifestForgetsWhatWasUnavailable() throws {
    var plan = WatchArtworkSyncPlan()
    _ = plan.receive(try manifest(["a"]), currentPhoneStamp: phone, synced: [])
    let result18 = plan.nextRequest(currentPhoneStamp: phone, synced: [], now: start)
    let wants = try #require(result18)
    _ = plan.receive(
      try WatchArtworkBundle(answering: wants, entries: [], unavailable: [cover("a")], isFinal: true),
      currentPhoneStamp: phone)
    let result19 = plan.nextRequest(currentPhoneStamp: phone, synced: [], now: start)
    #expect(result19 == nil)
    _ = plan.receive(try manifest(["a"]), currentPhoneStamp: phone, synced: [])
    let result20 = plan.nextRequest(currentPhoneStamp: phone, synced: [], now: start)
    #expect(result20 == nil, "same covers: still unavailable")
    _ = plan.receive(try manifest(["a", "b"]), currentPhoneStamp: phone, synced: [])
    let result21 = plan.nextRequest(currentPhoneStamp: phone, synced: [], now: start)
    #expect(result21?.covers == [cover("a"), cover("b")])
  }

  @Test func syncedCoversAreDrawnUnderTheWatchStampOnlyWhenThePhoneVouches() throws {
    var plan = WatchArtworkSyncPlan()
    #expect(plan.drawingStamps(localStamp: watch).isEmpty)
    _ = plan.receive(try manifest(["a"], authenticated: watch), currentPhoneStamp: phone, synced: [])
    #expect(plan.drawingStamps(localStamp: watch) == [phone, watch])
    #expect(plan.drawingStamps(localStamp: other) == [phone])
    #expect(plan.drawingStamps(localStamp: nil) == [phone])
    _ = plan.receive(try manifest(["a"]), currentPhoneStamp: phone, synced: [])
    #expect(plan.drawingStamps(localStamp: watch) == [phone])
  }

  @Test func statePersistsThroughCoding() throws {
    var plan = WatchArtworkSyncPlan()
    _ = plan.receive(try manifest(["a", "b"], authenticated: watch), currentPhoneStamp: phone, synced: [])
    _ = plan.nextRequest(currentPhoneStamp: phone, synced: [], now: start)
    let decoded = try JSONDecoder().decode(WatchArtworkSyncPlan.self, from: JSONEncoder().encode(plan))
    #expect(decoded == plan)
  }
}

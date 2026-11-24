import Foundation
import Testing

@testable import WatchProtocol

@Suite("WatchCatalogueCache")
struct WatchCatalogueCacheTests {
  private let account = WatchProtocolFixtures.accountStamp()
  private let otherAccount = WatchProtocolFixtures.otherAccountStamp()

  @Test func acceptsFreshMatchingContextAndRejectsStaleOrForeign() throws {
    let initial = try WatchCatalogueCache(expectedAccountStamp: account)
    let first = try WatchProtocolFixtures.snapshot(account: account, at: 100)
    guard case .accepted(let cached) = initial.applying(first, now: Date(timeIntervalSinceReferenceDate: 100)) else {
      Issue.record("matching context should be accepted")
      return
    }
    #expect(cached.snapshot == first)
    #expect(cached.applying(first, now: Date(timeIntervalSinceReferenceDate: 101)) == .rejected(.staleContext))
    let foreign = try WatchProtocolFixtures.snapshot(account: otherAccount, at: 200)
    #expect(cached.applying(foreign, now: Date(timeIntervalSinceReferenceDate: 200)) == .rejected(.foreignAccount))
  }

  @Test func acceptsBoundedFutureClockSkewAndRejectsLargerSkew() throws {
    let initial = try WatchCatalogueCache(expectedAccountStamp: account)
    let withinTolerance = try WatchProtocolFixtures.snapshot(account: account, at: 125)
    guard
      case .accepted = initial.applying(
        withinTolerance, now: Date(timeIntervalSinceReferenceDate: 100))
    else {
      Issue.record("paired context within clock-skew tolerance should be accepted")
      return
    }
    let beyondTolerance = try WatchProtocolFixtures.snapshot(account: account, at: 131)
    #expect(
      initial.applying(beyondTolerance, now: Date(timeIntervalSinceReferenceDate: 100))
        == .rejected(.invalidContext))
  }

  @Test func signedOutClearsAndExplicitResetAcceptsCoalescedLogin() throws {
    let cache = try WatchCatalogueCache(expectedAccountStamp: account)
    let signedOut = try WatchCatalogueSnapshot(
      accountStamp: nil, generatedAt: Date(timeIntervalSinceReferenceDate: 299), items: [])
    guard
      case .cleared(let cleared) = cache.applying(
        signedOut, now: Date(timeIntervalSinceReferenceDate: 299))
    else {
      Issue.record("signed-out context should clear")
      return
    }
    #expect(cleared.lastContextDate == signedOut.generatedAt)
    let fresh = try WatchProtocolFixtures.snapshot(account: otherAccount, at: 300)
    #expect(cleared.applying(fresh, now: Date(timeIntervalSinceReferenceDate: 300)) == .rejected(.accountResetRequired))
    let reset = cleared.resetAccount(to: otherAccount)
    guard case .accepted(let updated) = reset.applying(fresh, now: Date(timeIntervalSinceReferenceDate: 300)) else {
      Issue.record("explicit account reset should establish the new stamp")
      return
    }
    #expect(updated.expectedAccountStamp == otherAccount)
    guard
      case .accepted(let authoritative) = cache.resetAndApplyAuthoritative(
        fresh, now: Date(timeIntervalSinceReferenceDate: 300))
    else {
      Issue.record("authoritative account reset should accept the coalesced login")
      return
    }
    #expect(authoritative.expectedAccountStamp == otherAccount)
  }

  @Test func staleSignedOutAndOldSignedInContextsCannotCrossWatermark() throws {
    let cache = try WatchCatalogueCache(expectedAccountStamp: account)
    let fresh = try WatchProtocolFixtures.snapshot(account: account, at: 500)
    guard
      case .accepted(let withFresh) = cache.applying(
        fresh, now: Date(timeIntervalSinceReferenceDate: 500))
    else {
      Issue.record("fresh context should be accepted")
      return
    }
    let staleSignedOut = try WatchCatalogueSnapshot(
      accountStamp: nil, generatedAt: Date(timeIntervalSinceReferenceDate: 499), items: [])
    #expect(
      withFresh.applying(staleSignedOut, now: Date(timeIntervalSinceReferenceDate: 500))
        == .rejected(.staleContext))
    let currentSignedOut = try WatchCatalogueSnapshot(
      accountStamp: nil, generatedAt: Date(timeIntervalSinceReferenceDate: 501), items: [])
    guard
      case .cleared(let cleared) = withFresh.applying(
        currentSignedOut, now: Date(timeIntervalSinceReferenceDate: 501))
    else {
      Issue.record("newer signed-out context should clear")
      return
    }
    let oldSignedIn = try WatchProtocolFixtures.snapshot(account: otherAccount, at: 500)
    #expect(
      cleared.applying(oldSignedIn, now: Date(timeIntervalSinceReferenceDate: 502))
        == .rejected(.staleContext))
    let newerSignedIn = try WatchProtocolFixtures.snapshot(account: otherAccount, at: 502)
    guard
      case .accepted = cleared.resetAndApplyAuthoritative(
        newerSignedIn, now: Date(timeIntervalSinceReferenceDate: 502))
    else {
      Issue.record("newer authoritative context should establish the new account")
      return
    }
  }

  @Test func cachePersistenceUsesSharedPayloadKeyAndValidatesWire() throws {
    let cache = try WatchCatalogueCache(expectedAccountStamp: account)
    let data = try WatchWireCodec.encode(cache)
    #expect(WatchTransportKey.payload == "whirr.watch.payload")
    #expect(WatchTransportKey.payload == "whirr.watch.payload")
    #expect(try WatchWireCodec.decode(WatchCatalogueCache.self, from: data) == cache)
  }

  @Test func oldCacheWithoutWatermarkOrPlaybackStateMigratesFromSnapshot() throws {
    let data = Data(
      #"{"expectedAccountStamp":{"accountIdentityHash":"account-hash","serverIdentityHash":"server-hash"},"snapshot":{"version":1,"accountStamp":{"accountIdentityHash":"account-hash","serverIdentityHash":"server-hash"},"owner":"none","generatedAt":100,"items":[]}}"#
        .utf8)
    let cache = try WatchWireCodec.decode(WatchCatalogueCache.self, from: data)
    let snapshot = try #require(cache.snapshot)
    #expect(cache.expectedAccountStamp == snapshot.accountStamp)
    #expect(snapshot.items.isEmpty)
    #expect(snapshot.playbackState == .idle)
    #expect(cache.lastContextDate == Date(timeIntervalSinceReferenceDate: 100))
    #expect(try WatchProtocolFixtures.roundTrip(cache) == cache)
  }

  @Test func cacheBudgetIncludesNearLimitSnapshotAndRejectsOversizeWire() throws {
    let items = try (0..<90).map { index in
      try WatchCatalogueItem(
        id: "item-\(index)",
        selection: .audiobookshelf(itemID: "book-\(index)", episodeID: nil),
        title: String(repeating: "x", count: 401),
        subtitle: index == 0 ? String(repeating: "s", count: 100) : nil,
        capabilities: WatchSelectionCapabilities(phonePlayable: true, watchPlayable: false))
    }
    let snapshot = try WatchCatalogueSnapshot(
      accountStamp: account, generatedAt: Date(timeIntervalSinceReferenceDate: 1), items: items)
    let snapshotData = try WatchWireCodec.encode(snapshot)
    #expect(snapshotData.count <= WatchProtocolVersion.maxSnapshotBytes)

    let cache = try WatchCatalogueCache(expectedAccountStamp: account, snapshot: snapshot)
    let data = try WatchWireCodec.encode(cache)
    #expect(data.count > WatchProtocolVersion.maxSnapshotBytes)
    #expect(data.count <= WatchCatalogueCache.maxWireBytes)
    #expect(try WatchWireCodec.decode(WatchCatalogueCache.self, from: data) == cache)
    #expect(throws: WatchProtocolCodingError.tooLarge) {
      try WatchWireCodec.decode(
        WatchCatalogueCache.self,
        from:
          Data(repeating: 0, count: WatchCatalogueCache.maxWireBytes + 1))
    }
  }
}

import Foundation
import TestSupport
import Testing
import WatchProtocol

@testable import Whirr

@MainActor
@Suite("Watch application context delivery")
struct WatchCatalogueTransportTests {
  @Test func retimestampingPreservesPlaybackRate() async throws {
    var sent: [Data] = []
    let transport = WatchCatalogueTransport(
      lastTimestamp: Date(timeIntervalSince1970: 100),
      isReady: { true }, send: { sent.append($0) })
    let original = try WatchCatalogueSnapshot(
      accountStamp: WatchAccountStamp(accountIdentityHash: "account", serverIdentityHash: "server"),
      generatedAt: Date(timeIntervalSince1970: 99), items: [], playbackRate: 1.35,
      skipBackwardSeconds: 15, skipForwardSeconds: 45, playbackRatePresets: [0.9, 1, 1.1],
      followedPodcastsEnabled: true, removePlayedNativeEpisodes: false)
    transport.enqueue(original)
    await transport.settle()
    let result = try WatchWireCodec.decode(WatchCatalogueSnapshot.self, from: #require(sent.first))
    #expect(result.generatedAt > original.generatedAt)
    #expect(result.playbackRate == 1.35)
    #expect(result.skipBackwardSeconds == 15)
    #expect(result.skipForwardSeconds == 45)
    #expect(result.playbackRatePresets == [0.9, 1, 1.1])
    #expect(result.followedPodcastsEnabled == true)
    #expect(result.removePlayedNativeEpisodes == false)
  }
  @Test func inactivePublicationCoalescesAndFlushesOnlyLatest() async throws {
    let ready = Locked(false)
    var sent: [Data] = []
    let transport = WatchCatalogueTransport(isReady: { ready.value }, send: { sent.append($0) })
    transport.enqueue(try snapshot(at: 1))
    await transport.settle()
    transport.enqueue(try snapshot(at: 2))
    await transport.settle()
    #expect(sent.isEmpty)
    ready.value = true
    transport.flush()
    #expect(sent.count == 1)
    #expect(
      try WatchWireCodec.decode(WatchCatalogueSnapshot.self, from: #require(sent.first)).generatedAt
        == Date(timeIntervalSince1970: 2))
    #expect(transport.pending == nil)
  }

  @Test func failedSendRetainsLatestAndSignedOutReplacesOldAccount() async throws {
    enum Unavailable: Error { case refused }
    let failed = Locked(true)
    var sent: [Data] = []
    let transport = WatchCatalogueTransport(
      isReady: { true },
      send: {
        if failed.value { throw Unavailable.refused }
        sent.append($0)
      })
    transport.enqueue(try snapshot(at: 1))
    await transport.settle()
    #expect(transport.pending?.accountStamp != nil)
    transport.enqueue(
      try WatchCatalogueSnapshot(accountStamp: nil, generatedAt: Date(timeIntervalSince1970: 2), items: []))
    await transport.settle()
    failed.value = false
    transport.flush()
    let value = try WatchWireCodec.decode(WatchCatalogueSnapshot.self, from: #require(sent.first))
    #expect(value.accountStamp == nil)
    #expect(value.items.isEmpty)
    transport.flush()
    #expect(sent.count == 1)
  }

  @Test func graphRebuildAndClockRegressionKeepContextMonotonic() async throws {
    var sent: [Data] = []
    let transport = WatchCatalogueTransport(
      lastTimestamp: Date(timeIntervalSince1970: 100), isReady: { true },
      send: { sent.append($0) })
    transport.enqueue(try snapshot(at: 99))
    await transport.settle()
    transport.enqueue(try snapshot(at: 99))
    await transport.settle()
    let dates = try sent.map {
      try WatchWireCodec.decode(WatchCatalogueSnapshot.self, from: $0).generatedAt
    }
    #expect(dates.count == 2)
    #expect(dates[0] > Date(timeIntervalSince1970: 100))
    #expect(dates[1] > dates[0])
    #expect(sent.allSatisfy { $0.count <= WatchProtocolVersion.maxSnapshotBytes })
  }

  /// A publication runs several times a second, so a `UserDefaults.standard` write there must not
  /// invalidate every `@AppStorage` reader in the app.
  @Test("publishing never writes the dedup timestamp through; a lifecycle persist does")
  func publicationKeepsTheTimestampInMemory() async throws {
    var persisted: [Date] = []
    var sent: [Data] = []
    let transport = WatchCatalogueTransport(
      lastTimestamp: Date(timeIntervalSince1970: 100), isReady: { true },
      persistTimestamp: { persisted.append($0) }, send: { sent.append($0) })

    for second in 1...10 {
      transport.enqueue(try snapshot(at: Double(second)))
      await transport.settle()
    }
    #expect(sent.count == 10)
    #expect(persisted.isEmpty)

    transport.persistLastTimestamp()
    let written = try #require(persisted.first)
    #expect(persisted.count == 1)
    #expect(
      written
        == (try WatchWireCodec.decode(WatchCatalogueSnapshot.self, from: #require(sent.last)).generatedAt))

    // Nothing published in between, so a second boundary writes nothing.
    transport.persistLastTimestamp()
    #expect(persisted.count == 1)

    transport.enqueue(try snapshot(at: 20))
    await transport.settle()
    transport.persistLastTimestamp()
    #expect(persisted.count == 2)
    #expect(persisted[1] > written)
  }

  @Test("a process that published nothing writes back no timestamp it did not change")
  func persistWithoutPublicationWritesNothing() {
    var persisted: [Date] = []
    let transport = WatchCatalogueTransport(
      lastTimestamp: Date(timeIntervalSince1970: 100), isReady: { true },
      persistTimestamp: { persisted.append($0) }, send: { _ in })

    transport.persistLastTimestamp()

    #expect(persisted.isEmpty)
  }

  @Test("a retry re-sends the bytes the publication already encoded")
  func retryReusesTheEncodedPayload() async throws {
    enum Unavailable: Error { case refused }
    let failed = Locked(true)
    var sent: [Data] = []
    let transport = WatchCatalogueTransport(
      isReady: { true },
      send: {
        if failed.value { throw Unavailable.refused }
        sent.append($0)
      })

    transport.enqueue(try snapshot(at: 1))
    await transport.settle()
    #expect(sent.isEmpty)
    failed.value = false
    transport.flush()

    let value = try WatchWireCodec.decode(WatchCatalogueSnapshot.self, from: #require(sent.first))
    #expect(value.generatedAt == Date(timeIntervalSince1970: 1))
    #expect(transport.pending == nil)
  }

  /// The encode is the expensive half of a publication: the whole catalogue through `JSONEncoder`,
  /// twice a second while audio plays. It must not run on the main thread.
  @Test("a publication is encoded off the main thread")
  func encodingRunsOffTheMainThread() async throws {
    let encodedOnMain = Locked<[Bool]>([])
    var sent: [Data] = []
    let transport = WatchCatalogueTransport(
      isReady: { true },
      encode: { snapshot in
        encodedOnMain.withValue { $0.append(Thread.isMainThread) }
        return try WatchWireCodec.encode(snapshot)
      },
      send: { sent.append($0) })

    transport.enqueue(try snapshot(at: 1))
    await transport.settle()

    #expect(encodedOnMain.value == [false])
    #expect(sent.count == 1)
  }

  /// Delivery is latest-only, so a publication replaced before its encode began is skipped rather
  /// than encoded and sent only to be overwritten.
  @Test("a publication superseded before it is encoded is never encoded or sent")
  func supersededPublicationIsSkipped() async throws {
    let encodes = Locked(0)
    var sent: [Data] = []
    let transport = WatchCatalogueTransport(
      isReady: { true },
      encode: { snapshot in
        encodes.withValue { $0 += 1 }
        return try WatchWireCodec.encode(snapshot)
      },
      send: { sent.append($0) })

    transport.enqueue(try snapshot(at: 1))
    transport.enqueue(try snapshot(at: 2))
    await transport.settle()

    #expect(encodes.value == 1)
    #expect(sent.count == 1)
    #expect(
      try WatchWireCodec.decode(WatchCatalogueSnapshot.self, from: #require(sent.first)).generatedAt
        == Date(timeIntervalSince1970: 2))
  }

  private func snapshot(at seconds: Double) throws -> WatchCatalogueSnapshot {
    try WatchCatalogueSnapshot(
      accountStamp: WatchAccountStamp(accountIdentityHash: "account", serverIdentityHash: "server"),
      generatedAt: Date(timeIntervalSince1970: seconds), items: [])
  }
}

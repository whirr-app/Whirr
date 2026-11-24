import ABSApi
import Foundation
import ImageIO
import Persistence
import TestSupport
import Testing
import WatchProtocol

@testable import Whirr

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WatchPhoneArtworkEndpointTests {
  @Test func accountReplacementDuringLoadDiscardsTheImage() async throws {
    let original = try WatchAccountStamp(accountIdentityHash: "a", serverIdentityHash: "s")
    let replacement = try WatchAccountStamp(accountIdentityHash: "b", serverIdentityHash: "s")
    var stamp: WatchAccountStamp? = original
    let request = WatchArtworkRequest(
      accountStamp: original,
      reference: .init(selection: .audiobookshelf(itemID: "book", episodeID: nil)), size: .row)
    let endpoint = WatchPhoneArtworkEndpoint(
      currentStamp: { stamp },
      load: { _ in
        stamp = replacement
        return Data([1, 2, 3])
      })
    let result = WatchReplyGate<Data>()
    await endpoint.receive(try WatchWireCodec.encode(request)) { reply in
      result.finish(reply[WatchTransportKey.artworkReply] as? Data)
    }
    #expect(await result.wait() == nil)
  }

  /// The Watch gives up after 8 s, and the phone keeps loading what it abandoned, so a busy phone
  /// must wait for a slot rather than refuse the next request outright.
  /// The deadline is out of reach so a loaded machine cannot expire it; the deadline has its own test.
  @Test func aRequestArrivingWhileTwoLoadAWaitsForASlot() async throws {
    let stamp = try WatchAccountStamp(accountIdentityHash: "a", serverIdentityHash: "s")
    var held: [CheckedContinuation<Void, Never>] = []
    var loads = 0
    let endpoint = WatchPhoneArtworkEndpoint(
      currentStamp: { stamp },
      load: { _ in
        loads += 1
        if loads <= 2 { await withCheckedContinuation { held.append($0) } }
        return Data([UInt8(loads)])
      }, slotWait: .seconds(600))
    func request() throws -> Data {
      try WatchWireCodec.encode(
        WatchArtworkRequest(
          accountStamp: stamp, reference: .init(selection: .audiobookshelf(itemID: "book", episodeID: nil)),
          size: .row))
    }
    let first = try request()
    let second = try request()
    let third = try request()
    let busy = Task { await endpoint.receive(first) { _ in } }
    let alsoBusy = Task { await endpoint.receive(second) { _ in } }
    _ = await awaitCondition("two loads hold both slots") { held.count == 2 }
    let result = WatchReplyGate<Data>()
    let waiting = Task {
      await endpoint.receive(third) { reply in result.finish(reply[WatchTransportKey.artworkReply] as? Data) }
    }
    _ = await awaitQuiescence("the third request waits for a slot") { "\(loads)" }
    #expect(loads == 2)
    // Either busy request may own the first held load, so await only the waiter here: awaiting
    // the request whose load is still held would never return.
    held.removeFirst().resume()
    await waiting.value
    #expect(await result.wait() != nil)
    held.removeFirst().resume()
    await busy.value
    await alsoBusy.value
  }

  @Test func aRequestStillWaitingAtTheDeadlineGetsAnEmptyReply() async throws {
    let stamp = try WatchAccountStamp(accountIdentityHash: "a", serverIdentityHash: "s")
    var held: [CheckedContinuation<Void, Never>] = []
    var loads = 0
    let endpoint = WatchPhoneArtworkEndpoint(
      currentStamp: { stamp },
      load: { _ in
        loads += 1
        await withCheckedContinuation { held.append($0) }
        return Data([1])
      }, slotWait: .milliseconds(50))
    let payload = try WatchWireCodec.encode(
      WatchArtworkRequest(
        accountStamp: stamp, reference: .init(selection: .audiobookshelf(itemID: "book", episodeID: nil)),
        size: .row))
    let busy = (0..<2).map { _ in Task { await endpoint.receive(payload) { _ in } } }
    _ = await awaitCondition("two loads hold both slots") { held.count == 2 }
    var replied: [String: Any]?
    await endpoint.receive(payload) { replied = $0 }
    #expect(replied?.isEmpty == true)
    #expect(loads == 2)
    for continuation in held { continuation.resume() }
    for task in busy { await task.value }
  }

  @Test func malformedAndForeignRequestsNeverLoadArtwork() async throws {
    let stamp = try WatchAccountStamp(accountIdentityHash: "a", serverIdentityHash: "s")
    var loads = 0
    let endpoint = WatchPhoneArtworkEndpoint(
      currentStamp: { stamp },
      load: { _ in
        loads += 1
        return nil
      })
    let foreign = WatchArtworkRequest(
      accountStamp:
        try WatchAccountStamp(accountIdentityHash: "other", serverIdentityHash: "s"),
      reference: .init(selection: .nativeFeed(feedID: "1", episodeID: "2")), size: .row)
    await endpoint.receive(Data(repeating: 0, count: WatchArtworkRequest.maxWireBytes + 1)) { _ in }
    await endpoint.receive(try WatchWireCodec.encode(foreign)) { _ in }
    #expect(loads == 0)
  }

  @Test func thumbnailsAreResizedAndPreservePortraitAspectRatio() throws {
    for size in [WatchArtworkSize.row, .player] {
      let data = try #require(WatchArtworkThumbnail.prepare(ImageTestFixtures.knownGoodCoverData, size: size))
      #expect(data.count <= WatchArtworkReply.maxImageBytes)
      let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
      let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
      #expect(image.width == size.pixelWidth)
      #expect(image.height == size.pixelWidth)
    }
    let data = try #require(WatchArtworkThumbnail.prepare(ImageTestFixtures.portraitCoverData, size: .row))
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == 64)
    #expect(image.height == 96)
  }

  /// A cover replaced on the server must reach the Watch even when the Watch's reference is
  /// unversioned: the phone serves it from its own library's revision.
  @Test func phoneRevisionWinsForAnAudiobookshelfCover() {
    let reference = WatchArtworkReference(selection: .audiobookshelf(itemID: "book", episodeID: "ep"))
    let item = Self.item("book", serverUpdatedAt: Date(timeIntervalSince1970: 1_790_000_000.123))

    #expect(
      WatchCompanionRuntime.phoneArtworkRevision(for: reference, phoneItem: item)
        == ArtworkRevision("1790000000123"))
  }

  @Test func watchRevisionStandsWhenThePhoneCannotDateTheItem() {
    let reference = WatchArtworkReference(
      selection: .audiobookshelf(itemID: "book", episodeID: nil), revision: "1790000000000")

    #expect(
      WatchCompanionRuntime.phoneArtworkRevision(for: reference, phoneItem: nil)
        == ArtworkRevision("1790000000000"))
    #expect(
      WatchCompanionRuntime.phoneArtworkRevision(
        for: reference, phoneItem: Self.item("book", serverUpdatedAt: nil))
        == ArtworkRevision("1790000000000"))
    #expect(
      WatchCompanionRuntime.phoneArtworkRevision(
        for: reference, phoneItem: Self.item("other", serverUpdatedAt: Date()))
        == ArtworkRevision("1790000000000"))
  }

  private static func item(_ id: String, serverUpdatedAt: Date?) -> ItemSummary {
    ItemSummary.fixture(
      serverItemId: id, mediaKind: "book", title: "Gilead", author: nil, durationSeconds: nil,
      category: .audiobook, serverUpdatedAt: serverUpdatedAt)
  }

  @Test func thumbnailRejectsInvalidImageBytes() {
    #expect(WatchArtworkThumbnail.prepare(Data([1, 2, 3]), size: .player) == nil)
  }
}

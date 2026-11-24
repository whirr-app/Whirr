import Foundation
import Testing

@testable import WatchProtocol

struct WatchArtworkTests {
  let stamp = try! WatchAccountStamp(accountIdentityHash: "account", serverIdentityHash: "server")

  @Test func episodesShareCoverButSourcesAndSizesDoNotCollide() throws {
    let a = WatchArtworkReference(selection: .audiobookshelf(itemID: "42", episodeID: "one"))
    let b = WatchArtworkReference(selection: .audiobookshelf(itemID: "42", episodeID: "two"))
    let rss = WatchArtworkReference(selection: .nativeFeed(feedID: "42", episodeID: "one"))
    #expect(a == b)
    #expect(a != rss)
    #expect(WatchArtworkRequest(accountStamp: stamp, reference: a, size: .row).size.pixelWidth == 96)
    #expect(WatchArtworkSize.player.pixelWidth == 320)
  }

  @Test func roundTripAndReplyCorrelation() throws {
    let request = WatchArtworkRequest(
      accountStamp: stamp,
      reference: WatchArtworkReference(selection: .nativeFeed(feedID: "9", episodeID: "episode")), size: .row)
    #expect(try WatchWireCodec.decode(WatchArtworkRequest.self, from: WatchWireCodec.encode(request)) == request)
    let reply = WatchArtworkReply(request: request, imageData: Data([1, 2, 3]))
    #expect(try WatchWireCodec.decode(WatchArtworkReply.self, from: WatchWireCodec.encode(reply)).matches(request))
    #expect(!reply.matches(WatchArtworkRequest(accountStamp: stamp, reference: request.reference, size: .player)))
  }

  @Test func rejectsUnboundedImagesAndUnsafeReferences() throws {
    let request = WatchArtworkRequest(
      accountStamp: stamp,
      reference: WatchArtworkReference(selection: .audiobookshelf(itemID: "book", episodeID: nil)), size: .player)
    let reply = WatchArtworkReply(request: request, imageData: Data(repeating: 1, count: 40 * 1024 + 1))
    #expect(throws: WatchProtocolCodingError.tooLarge) { try WatchWireCodec.encode(reply) }
    let invalid = WatchArtworkRequest(
      accountStamp: stamp,
      reference: WatchArtworkReference(selection: .audiobookshelf(itemID: "https://server/secret", episodeID: nil)),
      size: .row)
    #expect(throws: (any Error).self) { try WatchWireCodec.encode(invalid) }
  }
}

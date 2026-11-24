import Foundation
import Testing
import WatchProtocol

@testable import WatchPlayback

/// A bookmark survives relaunch for both sources: an Audiobookshelf title and a native-feed episode
/// whose Watch-local copy the phone sent (ADR 0019).
@Suite struct WatchResumeBookmarkTests {
  private let stamp = try! WatchAccountStamp(accountIdentityHash: "account", serverIdentityHash: "server")
  private let book = WatchSelection.audiobookshelf(itemID: "book", episodeID: "episode")
  private let episode = WatchSelection.nativeFeed(feedID: "feed", episodeID: "episode")

  private func roundTrip(_ bookmark: WatchResumeBookmark) throws -> WatchResumeBookmark {
    try JSONDecoder().decode(WatchResumeBookmark.self, from: JSONEncoder().encode(bookmark))
  }

  @Test func aNativeFeedBookmarkRoundTrips() throws {
    let bookmark = try WatchResumeBookmark(accountStamp: stamp, selection: episode, position: 42)
    let decoded = try roundTrip(bookmark)
    #expect(decoded.accountStamp == stamp)
    #expect(decoded.selection == episode)
    #expect(decoded.position == 42)
  }

  @Test func anAudiobookshelfBookmarkRoundTrips() throws {
    let bookmark = try WatchResumeBookmark(accountStamp: stamp, selection: book, position: 7)
    let decoded = try roundTrip(bookmark)
    #expect(decoded.selection == book)
    #expect(decoded.position == 7)
  }

  /// The shape written before native feeds were accepted still decodes.
  @Test func aBookmarkWrittenBeforeNativeFeedsDecodes() throws {
    let json = Data(
      """
      {"accountStamp":{"accountIdentityHash":"account","serverIdentityHash":"server"},
       "selection":{"source":"audiobookshelf","itemID":"book","episodeID":"episode"},
       "position":12.5}
      """.utf8)
    let decoded = try JSONDecoder().decode(WatchResumeBookmark.self, from: json)
    #expect(decoded.accountStamp == stamp)
    #expect(decoded.selection == book)
    #expect(decoded.position == 12.5)
  }

  @Test func anUnsafeSelectionIsRejected() {
    #expect(throws: WatchProtocolCodingError.self) {
      try WatchResumeBookmark(
        accountStamp: stamp, selection: .nativeFeed(feedID: "https://example.invalid", episodeID: "episode"),
        position: 1)
    }
  }

  @Test func aPositionOutsideTheHandoffLimitsIsRejected() {
    #expect(throws: WatchHandoffError.self) {
      try WatchResumeBookmark(accountStamp: stamp, selection: episode, position: -1)
    }
  }
}

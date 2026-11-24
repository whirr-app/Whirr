import ABSApi
import Foundation
import Persistence
import TestSupport
import Testing

@testable import Whirr

/// The reader's answers, one stream per followed episode, pushed by hand.
private final class FakeEpisodeArtworkReader: RSSEpisodeArtworkReading, @unchecked Sendable {
  private let lock = NSLock()
  private var continuations: [String: AsyncStream<URL?>.Continuation] = [:]
  private var requests: [String] = []

  var requested: [String] {
    lock.withLock { requests }
  }

  func observeEpisodeArtworkURL(feedId: Int64, identityKey: String) -> AsyncStream<URL?> {
    let name = "\(feedId)/\(identityKey)"
    return AsyncStream { continuation in
      lock.withLock {
        requests.append(name)
        continuations[name] = continuation
      }
    }
  }

  func emit(_ url: URL?, feedId: Int64 = 7, identityKey: String) {
    let continuation = lock.withLock { continuations["\(feedId)/\(identityKey)"] }
    continuation?.yield(url)
  }
}

@MainActor
@Suite("Player episode artwork")
struct PlayerEpisodeArtworkTests {
  private static let feedURL = URL(string: "https://feeds.example.test/show.xml")!
  private static let first = URL(string: "https://img.example.test/first.jpg")!
  private static let second = URL(string: "https://img.example.test/second.jpg")!

  @Test("a playing RSS episode answers with its own image, under the show's feed identity")
  func emitsTheEpisodeSource() async {
    let reader = FakeEpisodeArtworkReader()
    let model = PlayerEpisodeArtwork(reading: reader)

    model.track(itemID: "rss:7", episodeID: "e1")
    #expect(await awaitCondition("settled") { reader.requested.isEmpty == false }.isObserved)
    #expect(reader.requested == ["7/e1"])
    #expect(model.source(itemID: "rss:7", episodeID: "e1", feedURL: Self.feedURL) == nil)

    reader.emit(Self.first, identityKey: "e1")
    #expect(
      await awaitCondition("settled") { model.source(itemID: "rss:7", episodeID: "e1", feedURL: Self.feedURL) != nil }
        .isObserved)
    #expect(
      model.source(itemID: "rss:7", episodeID: "e1", feedURL: Self.feedURL)
        == makeEpisodeArtworkSource(
          itemID: "rss:7", episodeArtworkURL: Self.first, artworkFeedURL: Self.feedURL))
  }

  @Test("a new URL replaces the old one, and none clears it")
  func updatesWhenTheReaderEmits() async {
    let reader = FakeEpisodeArtworkReader()
    let model = PlayerEpisodeArtwork(reading: reader)
    model.track(itemID: "rss:7", episodeID: "e1")
    #expect(await awaitCondition("settled") { reader.requested.isEmpty == false }.isObserved)

    reader.emit(Self.first, identityKey: "e1")
    #expect(await awaitCondition("settled") { model.urls.isEmpty == false }.isObserved)
    reader.emit(Self.second, identityKey: "e1")
    #expect(await awaitCondition("settled") { model.urls.values.first == Self.second }.isObserved)
    #expect(model.urls.values.first == Self.second)

    reader.emit(nil, identityKey: "e1")
    #expect(await awaitCondition("settled") { model.urls.isEmpty }.isObserved)
    #expect(model.source(itemID: "rss:7", episodeID: "e1", feedURL: Self.feedURL) == nil)
  }

  @Test("an Audiobookshelf item, or an item with no episode, follows nothing")
  func absAndBooksAnswerNil() async {
    let reader = FakeEpisodeArtworkReader()
    let model = PlayerEpisodeArtwork(reading: reader)

    model.track(itemID: "li_abs", episodeID: "ep_1")
    model.track(itemID: "rss:7", episodeID: nil)

    #expect(reader.requested.isEmpty)
    #expect(model.source(itemID: "li_abs", episodeID: "ep_1", feedURL: Self.feedURL) == nil)
    #expect(model.source(itemID: "rss:7", episodeID: nil, feedURL: Self.feedURL) == nil)
  }

  @Test("following the same episode twice opens one observation, and two episodes keep two answers")
  func oneObservationPerEpisode() async {
    let reader = FakeEpisodeArtworkReader()
    let model = PlayerEpisodeArtwork(reading: reader)

    model.track(itemID: "rss:7", episodeID: "e1")
    model.track(itemID: "rss:7", episodeID: "e1")
    model.track(itemID: "rss:7", episodeID: "e2")
    #expect(await awaitCondition("settled") { reader.requested.count >= 2 }.isObserved)
    reader.emit(Self.first, identityKey: "e1")
    reader.emit(Self.second, identityKey: "e2")
    #expect(await awaitCondition("settled") { model.urls.count == 2 }.isObserved)

    #expect(reader.requested == ["7/e1", "7/e2"])
    #expect(model.urls.count == 2)
  }

  @Test("only a few episodes are followed at once, and the oldest is dropped first")
  func boundedFollowing() async {
    let reader = FakeEpisodeArtworkReader()
    let model = PlayerEpisodeArtwork(reading: reader)
    for index in 1...5 { model.track(itemID: "rss:7", episodeID: "e\(index)") }
    #expect(await awaitCondition("settled") { reader.requested.count == 5 }.isObserved)
    reader.emit(Self.first, identityKey: "e1")
    reader.emit(Self.second, identityKey: "e5")
    #expect(await awaitCondition("settled") { model.urls.count == 1 }.isObserved)

    #expect(model.urls.keys.map(\.episodeID) == ["e5"])
  }
}

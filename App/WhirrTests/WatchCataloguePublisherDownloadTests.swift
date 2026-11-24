import AppModel
import Foundation
import Persistence
import TestSupport
import Testing
import WatchProtocol

@testable import Whirr

@MainActor
@Suite("Watch catalogue publisher downloads", .serialized)
struct WatchCataloguePublisherDownloadTests {
  /// The catalogue lists finished downloads only. Each publication is assembled, then validated and
  /// sent to the Watch on the main actor, so republishing for every 2% of an in-flight transfer
  /// stuttered phone scrolling for the whole download.
  @Test("an in-flight RSS download's progress does not republish; its completion does")
  func inFlightProgressDoesNotRepublish() async throws {
    let identities = AsyncStream<AccountIdentity?>.makeStream()
    let downloads = AsyncStream<[RSSDownloadedFeed]>.makeStream()
    var publications: [WatchCatalogueSnapshot] = []
    let publisher = WatchCataloguePublisher(
      rssDownloads: StreamRSSDownloadsReading(stream: downloads.stream),
      accountIdentity: StreamAccountIdentity(stream: identities.stream),
      minimumPublicationInterval: .milliseconds(20),
      publish: { snapshot in publications.append(snapshot) })
    defer { publisher.stop() }
    publisher.start()
    identities.continuation.yield(
      AccountIdentity(id: 7, clientUUID: "downloads", serverIdentityFingerprint: "server"))
    downloads.continuation.yield([Self.feed(state: .downloading, bytes: 0)])
    #expect(
      await awaitCondition(
        "the first publication", observing: { "\(publications.count) publications" },
        until: { publications.isEmpty == false }
      ).isObserved)
    #expect(
      await awaitQuiescence("baseline settles", stableFor: 150) { String(publications.count) }.isObserved)
    let baseline = publications.count

    for bytes: Int64 in stride(from: 20, through: 980, by: 20) {
      downloads.continuation.yield([Self.feed(state: .downloading, bytes: bytes)])
    }
    #expect(
      await awaitQuiescence("progress does not republish", stableFor: 150) { String(publications.count) }
        .isObserved)
    #expect(publications.count == baseline)

    downloads.continuation.yield([Self.feed(state: .completed, bytes: 1000)])
    #expect(
      await awaitCondition(
        "the completion to republish",
        observing: { "\(publications.count) publications, baseline \(baseline)" },
        until: { publications.count > baseline }
      ).isObserved)
  }

  private static func feed(state: DownloadState, bytes: Int64) -> RSSDownloadedFeed {
    RSSDownloadedFeed(
      id: 1, title: "Feed", sourceURL: URL(string: "https://feeds.example.test/feed.xml")!,
      episodes: [
        RSSDownloadedEpisode(
          id: "episode", title: "Episode", state: state, actualBytes: bytes, expectedBytes: 1000,
          holdReason: nil)
      ])
  }
}

private struct StreamRSSDownloadsReading: RSSDownloadsReading {
  let stream: AsyncStream<[RSSDownloadedFeed]>
  func observeRSSDownloads() -> AsyncStream<[RSSDownloadedFeed]> { stream }
}

private struct StreamAccountIdentity: AccountIdentityReading {
  let stream: AsyncStream<AccountIdentity?>
  func observeAccountIdentity() -> AsyncStream<AccountIdentity?> { stream }
}

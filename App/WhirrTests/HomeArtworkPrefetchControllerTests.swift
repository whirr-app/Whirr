import ABSApi
import AppModel
import Foundation
import Persistence
import Testing

@testable import Whirr

@MainActor
struct HomeArtworkPrefetchControllerTests {
  @Test("two observations for one Home shelf reuse its prefetcher")
  func reusesOnePrefetcherPerSection() throws {
    var created: [RecordingHomeArtworkPrefetcher] = []
    let controller = HomeArtworkPrefetchController(prefetcherFactory: {
      let prefetcher = RecordingHomeArtworkPrefetcher()
      created.append(prefetcher)
      return prefetcher
    })
    let client = try makeCoverClient()

    controller.observe(
      section: .continueListening, visibleIndex: 0, orderedIDs: ["one"], displaySize: 140,
      displayScale: 2, client: client, revisionsByID: [:])
    controller.observe(
      section: .continueListening, visibleIndex: 0, orderedIDs: ["one"], displaySize: 140,
      displayScale: 2, client: client, revisionsByID: [:])

    #expect(created.count == 1)
    #expect(created[0].observeCount == 2)
    #expect(controller.retainedSectionCount == 1)
  }

  /// Episodes of one show share `itemID`, as episode ids are only unique within their show. The
  /// keyed map must tolerate those repeats, since `Dictionary(uniqueKeysWithValues:)` traps on a
  /// duplicate. Only `rss:` items have a provider source, so ABS items never produced a repeat.
  @Test("two episodes of one show collapse to a single artwork source instead of trapping")
  func repeatedShowIDsFoldRatherThanTrap() {
    let artworkURL = URL(string: "https://feed.example.com/art.jpg")!
    let feedURL = URL(string: "https://feed.example.com/rss.xml")!
    func episode(_ episodeID: String) -> HomePodcastEpisode {
      HomePodcastEpisode(
        itemID: "rss:7", showTitle: "One Show", showAuthor: nil, episodeID: episodeID,
        title: "Episode \(episodeID)", subtitle: nil, publishedAt: Date(timeIntervalSince1970: 0),
        durationSeconds: 60, artworkURL: artworkURL, artworkFeedURL: feedURL)
    }
    let episodes = [episode("a"), episode("b"), episode("c")]

    // Every episode carries a source, so all three reach the dictionary and collide on one key.
    #expect(episodes.allSatisfy { $0.providerArtworkSource != nil })

    let sources = HomeArtworkPrefetching.sourcesByID(for: .podcastEpisodes(episodes))

    #expect(sources.count == 1)
    #expect(sources["rss:7"] == episodes[0].providerArtworkSource)
    // The ordered list keeps the repeat. Folding belongs to the keyed map alone.
    #expect(
      HomeArtworkPrefetching.orderedIDs(for: .podcastEpisodes(episodes))
        == ["rss:7", "rss:7", "rss:7"])
  }

  @Test("cancelAll cancels and clears every Home shelf prefetcher")
  func cancelAllRetiresEverySection() throws {
    var created: [RecordingHomeArtworkPrefetcher] = []
    let controller = HomeArtworkPrefetchController(prefetcherFactory: {
      let prefetcher = RecordingHomeArtworkPrefetcher()
      created.append(prefetcher)
      return prefetcher
    })
    let client = try makeCoverClient()

    for (index, section) in HomeMoreSection.allCases.prefix(3).enumerated() {
      controller.observe(
        section: section, visibleIndex: index, orderedIDs: ["item-\(index)"], displaySize: 140,
        displayScale: 2, client: client, revisionsByID: [:])
    }

    controller.cancelAll()

    #expect(created.count == 3)
    #expect(created.allSatisfy { $0.cancelCount == 1 })
    #expect(controller.retainedSectionCount == 0)
  }

  private func makeCoverClient() throws -> CoverImageClient {
    CoverImageClient(
      server: try ABSServerConfig(url: #require(URL(string: "https://example.test"))))
  }
}

@MainActor
private final class RecordingHomeArtworkPrefetcher: HomeArtworkPrefetcher {
  var observeCount = 0
  var cancelCount = 0

  func observe(
    visibleIndex: Int,
    orderedIDs: [String],
    displaySize: CGFloat,
    displayScale: CGFloat,
    client: any ArtworkServing,
    sourcesByID: [String: ArtworkSource],
    revisionsByID: [String: ArtworkRevision]
  ) {
    observeCount += 1
  }

  func cancel() {
    cancelCount += 1
  }
}

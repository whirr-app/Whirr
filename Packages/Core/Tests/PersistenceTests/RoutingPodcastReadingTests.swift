import Foundation
import Persistence
import TestSupport
import Testing

@Suite(.timeLimit(.minutes(1))) struct RoutingPodcastReadingTests {
  @Test func routesEachOperationAndRejectsUndecodableIds() async throws {
    let abs = Self.reading(label: "abs")
    let rss = Self.reading(label: "rss")
    let reading = RoutingPodcastReading(abs: abs, rss: rss)

    #expect(
      try #require(await AsyncStreamTestSupport.first(reading.observeEpisodes(itemId: "li_abc"))).first?.id
        == "abs")
    #expect(
      try #require(await AsyncStreamTestSupport.first(reading.observeEpisodes(itemId: "rss:7"))).first?.id
        == "rss")
    #expect(abs.observedEpisodeItemIDs == ["li_abc"])
    #expect(rss.observedEpisodeItemIDs == ["rss:7"])

    #expect(
      try #require(await AsyncStreamTestSupport.first(reading.observeShowDiagnostics(itemId: "li_abc")))?
        .autoDownloadEpisodes
        == true)
    #expect(
      try #require(await AsyncStreamTestSupport.first(reading.observeShowDiagnostics(itemId: "rss:7")))?
        .autoDownloadEpisodes
        == false)
    #expect(abs.observedDiagnosticsItemIDs == ["li_abc"])
    #expect(rss.observedDiagnosticsItemIDs == ["rss:7"])

    let absContext = try #require(await reading.episode(itemID: "li_abc", episodeID: "episode/1"))
    let rssContext = try #require(await reading.episode(itemID: "rss:7", episodeID: "episode/2"))
    #expect(absContext.showTitle == "abs")
    #expect(rssContext.showTitle == "rss")
    #expect(abs.episodeReadItemIDs == ["li_abc"])
    #expect(abs.episodeReadEpisodeIDs == ["episode/1"])
    #expect(rss.episodeReadItemIDs == ["rss:7"])
    #expect(rss.episodeReadEpisodeIDs == ["episode/2"])

    #expect(try await reading.recentEpisodeDescriptions(itemId: "li_abc", limit: 3) == ["abs"])
    #expect(try await reading.recentEpisodeDescriptions(itemId: "rss:7", limit: 3) == ["rss"])

    #expect(reading.episodePrefix(itemId: "li_abc", limit: 5)?.episodes.map(\.id) == ["abs"])
    #expect(reading.episodePrefix(itemId: "rss:7", limit: 5)?.episodes.map(\.id) == ["rss"])

    for itemID in ["", "rss:007"] {
      #expect(try await reading.recentEpisodeDescriptions(itemId: itemID, limit: 3) == [])
      #expect(await AsyncStreamTestSupport.first(reading.observeEpisodes(itemId: itemID)) == nil)
      #expect(await AsyncStreamTestSupport.first(reading.observeShowDiagnostics(itemId: itemID)) == nil)
      #expect(try await reading.episode(itemID: itemID, episodeID: "ignored") == nil)
      #expect(reading.episodePrefix(itemId: itemID, limit: 5) == nil)
    }
    #expect(abs.observedEpisodeItemIDs == ["li_abc"])
    #expect(rss.observedEpisodeItemIDs == ["rss:7"])
    #expect(abs.observedDiagnosticsItemIDs == ["li_abc"])
    #expect(rss.observedDiagnosticsItemIDs == ["rss:7"])
    #expect(abs.episodeReadItemIDs == ["li_abc"])
    #expect(abs.episodeReadEpisodeIDs == ["episode/1"])
    #expect(rss.episodeReadItemIDs == ["rss:7"])
    #expect(rss.episodeReadEpisodeIDs == ["episode/2"])
  }

  /// A reader that answers every operation with a value naming `label`, so a test can tell which
  /// source a call was routed to.
  private static func reading(label: String) -> FakePodcastReading {
    let reading = FakePodcastReading(episodes: [summary(id: label, label: label)])
    reading.pushDiagnostics(
      PodcastShowDiagnostics(autoDownloadEpisodes: label == "abs", lastEpisodeCheck: nil))
    reading.stubEpisodePrefix(
      PodcastEpisodePrefix(episodes: [summary(id: label, label: label)], isComplete: true))
    reading.stubRecentDescriptions([label])
    for episodeID in ["episode/1", "episode/2"] {
      reading.stubEpisode(
        PodcastEpisodeContext(
          episode: summary(id: episodeID, label: label), showTitle: label, showAuthor: nil,
          artworkURL: nil, artworkFeedURL: nil))
    }
    return reading
  }

  private static func summary(id: String, label: String) -> PodcastEpisodeSummary {
    PodcastEpisodeSummary(
      id: id, title: label, subtitle: nil, episodeDescription: nil,
      seasonNumber: nil, episodeNumber: nil, episodeType: nil, durationSeconds: nil, sizeBytes: nil,
      publishedAt: nil, progressSeconds: 0, isPlayed: false, isFinished: false,
      downloadStatus: .notDownloaded, isAvailableOnServer: true)
  }
}

extension FakePodcastReading {
  fileprivate var observedEpisodeItemIDs: [String] {
    calls.compactMap { call -> String? in
      if case .observeEpisodes(let itemID) = call { return itemID }
      return nil
    }
  }

  fileprivate var observedDiagnosticsItemIDs: [String] {
    calls.compactMap { call -> String? in
      if case .observeShowDiagnostics(let itemID) = call { return itemID }
      return nil
    }
  }

  fileprivate var episodeReadItemIDs: [String] {
    calls.compactMap { call -> String? in
      if case .episode(let itemID, _) = call { return itemID }
      return nil
    }
  }

  fileprivate var episodeReadEpisodeIDs: [String] {
    calls.compactMap { call -> String? in
      if case .episode(_, let episodeID) = call { return episodeID }
      return nil
    }
  }
}

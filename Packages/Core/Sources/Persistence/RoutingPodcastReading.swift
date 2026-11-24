/// Routes podcast reads by the typed source encoded in the serialized item id.
/// An undecodable id is a bug upstream; answering "no such show" avoids guessing a source.
public struct RoutingPodcastReading: PodcastReading, Sendable {
  private let abs: any PodcastReading
  private let rss: any PodcastReading

  public init(abs: any PodcastReading, rss: any PodcastReading) {
    self.abs = abs
    self.rss = rss
  }

  public func observeEpisodes(itemId: String) -> AsyncStream<[PodcastEpisodeSummary]> {
    guard let reading = reading(for: itemId) else { return Self.emptyStream() }
    return reading.observeEpisodes(itemId: itemId)
  }

  public func episodePrefix(itemId: String, limit: Int) -> PodcastEpisodePrefix? {
    reading(for: itemId)?.episodePrefix(itemId: itemId, limit: limit)
  }

  public func observeShowDiagnostics(itemId: String) -> AsyncStream<PodcastShowDiagnostics?> {
    guard let reading = reading(for: itemId) else { return Self.emptyStream() }
    return reading.observeShowDiagnostics(itemId: itemId)
  }

  public func episode(itemID: String, episodeID: String) async throws -> PodcastEpisodeContext? {
    guard let reading = reading(for: itemID) else { return nil }
    return try await reading.episode(itemID: itemID, episodeID: episodeID)
  }

  public func recentEpisodeDescriptions(itemId: String, limit: Int) async throws -> [String] {
    guard let reading = reading(for: itemId) else { return [] }
    return try await reading.recentEpisodeDescriptions(itemId: itemId, limit: limit)
  }

  public func observeEpisodeDownloadProgress(itemId: String) -> AsyncStream<[String: Double]> {
    guard let reading = reading(for: itemId) else { return Self.emptyStream() }
    return reading.observeEpisodeDownloadProgress(itemId: itemId)
  }

  public func observeServerCopyItemIDs(podcastFeedFingerprint: String) -> AsyncStream<[String]> {
    abs.observeServerCopyItemIDs(podcastFeedFingerprint: podcastFeedFingerprint)
  }

  private func reading(for itemId: String) -> (any PodcastReading)? {
    guard let identity = PodcastSourceIdentity(itemId: itemId) else { return nil }
    return switch identity.source {
    case .abs: abs
    case .rss: rss
    }
  }

  private static func emptyStream<Element>() -> AsyncStream<Element> {
    AsyncStream { $0.finish() }
  }
}

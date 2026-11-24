import Foundation
import Persistence

/// Routes podcast refreshes by the typed source encoded in the serialized item id.
/// An undecodable id is a bug upstream; answering "no such show" avoids guessing a source.
public struct RoutingPodcastRefreshing: PodcastRefreshing, Sendable {
  private let abs: any PodcastRefreshing
  private let rss: any PodcastRefreshing

  public init(abs: any PodcastRefreshing, rss: any PodcastRefreshing) {
    self.abs = abs
    self.rss = rss
  }

  public func refresh(itemID: String) async throws -> PodcastRefreshOutcome {
    guard let identity = PodcastSourceIdentity(itemId: itemID) else { return .complete }
    return switch identity.source {
    case .abs:
      try await abs.refresh(itemID: itemID)
    case .rss:
      try await rss.refresh(itemID: itemID)
    }
  }

  public func refreshIfStale(itemID: String, maximumAge: TimeInterval) async throws
    -> PodcastRefreshOutcome
  {
    guard let identity = PodcastSourceIdentity(itemId: itemID) else { return .complete }
    return switch identity.source {
    case .abs:
      try await abs.refreshIfStale(itemID: itemID, maximumAge: maximumAge)
    case .rss:
      try await rss.refreshIfStale(itemID: itemID, maximumAge: maximumAge)
    }
  }
}

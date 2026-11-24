import Foundation
import Persistence

/// Disarms the native refresh leg while device-owned subscriptions are disabled.
public struct NativePodcastSubscriptionsGatedRefreshing: PodcastRefreshing, Sendable {
  private let child: any PodcastRefreshing
  private let reading: any NativePodcastSubscriptionsReading

  public init(
    child: any PodcastRefreshing,
    reading: any NativePodcastSubscriptionsReading
  ) {
    self.child = child
    self.reading = reading
  }

  public func refresh(itemID: String) async throws -> PodcastRefreshOutcome {
    guard await reading.isEnabled() else { return .complete }
    return try await child.refresh(itemID: itemID)
  }

  public func refreshIfStale(itemID: String, maximumAge: TimeInterval) async throws
    -> PodcastRefreshOutcome
  {
    guard await reading.isEnabled() else { return .complete }
    return try await child.refreshIfStale(itemID: itemID, maximumAge: maximumAge)
  }
}

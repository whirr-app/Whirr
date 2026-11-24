import Foundation
import GRDB

public enum RSSNotificationRoute: Codable, Sendable, Equatable {
  case episode(feedID: Int64, identityKey: String)
  case show(feedID: Int64)
  case latest(feedIDs: [Int64])
}

/// A feed's device-owned notification policy. Unknown stored values fail closed to `disabled`.
public enum RSSNotificationOverride: String, Codable, Sendable, Equatable,
  DatabaseValueConvertible
{
  case inherit
  case enabled
  case disabled

  public static func parse(_ rawValue: String?) -> Self {
    guard let rawValue else { return .inherit }
    return Self(rawValue: rawValue) ?? .disabled
  }

  public func resolves(globalEnabled: Bool) -> Bool {
    switch self {
    case .inherit: globalEnabled
    case .enabled: true
    case .disabled: false
    }
  }
}

/// Why a durable first sighting can or cannot still produce a local notification.
public enum RSSNotificationDisposition: String, Codable, Sendable, Equatable,
  DatabaseValueConvertible
{
  case silentBaseline
  case pending
  case suppressedForeground
  case suppressedDisabled
  case suppressedIneligible
  case suppressedLifecycle
  case scheduled
  case alias
}

/// Refresh-time facts required to classify a first sighting inside `applyRefresh`'s transaction.
public struct RSSNotificationDiscoveryContext: Sendable, Equatable {
  public enum Source: Sendable, Equatable {
    case foreground
    case background
  }

  public var source: Source
  public var globalEnabled: Bool
  public var discoveredAt: Date

  public init(source: Source, globalEnabled: Bool, discoveredAt: Date) {
    self.source = source
    self.globalEnabled = globalEnabled
    self.discoveredAt = discoveredAt
  }

  public static func foreground(discoveredAt: Date) -> Self {
    Self(source: .foreground, globalEnabled: false, discoveredAt: discoveredAt)
  }

  public static func background(globalEnabled: Bool, discoveredAt: Date) -> Self {
    Self(source: .background, globalEnabled: globalEnabled, discoveredAt: discoveredAt)
  }
}

/// Shared seven-day meaning of a recent podcast episode. AppModel's `HomeRecency` delegates here.
public enum PodcastEpisodeRecency {
  public static let window: TimeInterval = 7 * 24 * 60 * 60

  public static func cutoff(now: Date) -> Date {
    now.addingTimeInterval(-window)
  }
}

public struct RSSNotificationCandidate: Sendable, Equatable, Hashable {
  public let feedID: Int64
  public let identityKey: String
  public let showTitle: String
  public let episodeTitle: String
  public let publishedAt: Date

  public init(
    feedID: Int64, identityKey: String, showTitle: String, episodeTitle: String,
    publishedAt: Date
  ) {
    self.feedID = feedID
    self.identityKey = identityKey
    self.showTitle = showTitle
    self.episodeTitle = episodeTitle
    self.publishedAt = publishedAt
  }
}

import Foundation

public enum WatchPlaybackState: String, Codable, Sendable, Equatable {
  case idle
  case preparing
  case paused
  case playing
  case failed
  case unresolved
}

extension WatchPlaybackState {
  /// True while the phone has a playback session: anything but idle or an unresolved audio activation.
  public var phoneHasSession: Bool {
    switch self {
    case .preparing, .paused, .playing, .failed: return true
    case .idle, .unresolved: return false
    }
  }
}

/// A latest-only catalogue payload sent by the phone. An empty snapshot with no account stamp is
/// the signed-out context; it cannot carry rows.
public struct WatchCatalogueSnapshot: WatchWireValue, Equatable {
  public static let maxWireBytes = WatchProtocolVersion.maxSnapshotBytes
  public let version: Int
  public let accountStamp: WatchAccountStamp?
  /// Stable authenticated server/user identity for matching independently signed-in devices.
  public let authenticatedAccountStamp: WatchAccountStamp?
  public let playbackState: WatchPlaybackState
  public let playbackRate: Double?
  /// Phone preferences are independent of the current playback state and survive offline use.
  public let skipBackwardSeconds: Int?
  public let skipForwardSeconds: Int?
  public let playbackRatePresets: [Double]?
  /// Whether the phone has native RSS subscriptions on, so the Watch can offer its followed shows.
  /// nil from an older phone that does not say.
  public let followedPodcastsEnabled: Bool?
  /// Whether the Watch removes a received copy once the phone records the episode finished. The
  /// phone setting defaults to on, so nil from an older phone means on.
  public let removePlayedNativeEpisodes: Bool?
  public let generatedAt: Date
  public let items: [WatchCatalogueItem]

  public init(
    accountStamp: WatchAccountStamp?,
    generatedAt: Date = Date(),
    items: [WatchCatalogueItem],
    playbackState: WatchPlaybackState = .idle,
    authenticatedAccountStamp: WatchAccountStamp? = nil,
    playbackRate: Double? = nil,
    skipBackwardSeconds: Int? = nil,
    skipForwardSeconds: Int? = nil,
    playbackRatePresets: [Double]? = nil,
    followedPodcastsEnabled: Bool? = nil,
    removePlayedNativeEpisodes: Bool? = nil
  ) throws {
    self.version = WatchProtocolVersion.current
    self.accountStamp = accountStamp
    self.authenticatedAccountStamp = authenticatedAccountStamp
    self.playbackState = playbackState
    self.playbackRate = playbackRate
    self.skipBackwardSeconds = skipBackwardSeconds
    self.skipForwardSeconds = skipForwardSeconds
    self.playbackRatePresets = playbackRatePresets
    self.followedPodcastsEnabled = followedPodcastsEnabled
    self.removePlayedNativeEpisodes = removePlayedNativeEpisodes
    self.generatedAt = generatedAt
    self.items = items
    try validate()
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let version = try container.decode(Int.self, forKey: .version)
    guard version == WatchProtocolVersion.current else {
      throw WatchProtocolCodingError.unsupportedVersion(version)
    }
    self.version = version
    self.accountStamp = try container.decodeIfPresent(WatchAccountStamp.self, forKey: .accountStamp)
    self.authenticatedAccountStamp = try container.decodeIfPresent(
      WatchAccountStamp.self, forKey: .authenticatedAccountStamp)
    self.playbackState = try container.decodeIfPresent(WatchPlaybackState.self, forKey: .playbackState) ?? .idle
    self.playbackRate = try container.decodeIfPresent(Double.self, forKey: .playbackRate)
    self.skipBackwardSeconds = try container.decodeIfPresent(Int.self, forKey: .skipBackwardSeconds)
    self.skipForwardSeconds = try container.decodeIfPresent(Int.self, forKey: .skipForwardSeconds)
    self.playbackRatePresets = try container.decodeIfPresent([Double].self, forKey: .playbackRatePresets)
    self.followedPodcastsEnabled = try container.decodeIfPresent(Bool.self, forKey: .followedPodcastsEnabled)
    self.removePlayedNativeEpisodes = try container.decodeIfPresent(
      Bool.self, forKey: .removePlayedNativeEpisodes)
    self.generatedAt = try container.decode(Date.self, forKey: .generatedAt)
    self.items = try container.decode([WatchCatalogueItem].self, forKey: .items)
    try validate()
  }

  public func validate() throws {
    try accountStamp?.validate()
    try authenticatedAccountStamp?.validate()
    for interval in [skipBackwardSeconds, skipForwardSeconds].compactMap({ $0 }) {
      guard accountStamp != nil, [10, 15, 30, 45, 60, 75, 90].contains(interval) else {
        throw WatchProtocolCodingError.invalidValue
      }
    }
    if let playbackRatePresets {
      guard accountStamp != nil, (1...8).contains(playbackRatePresets.count),
        playbackRatePresets.allSatisfy({ $0.isFinite && (0.5...3).contains($0) }),
        Set(playbackRatePresets).count == playbackRatePresets.count,
        playbackRatePresets == playbackRatePresets.sorted()
      else { throw WatchProtocolCodingError.invalidValue }
    }
    guard followedPodcastsEnabled == nil || accountStamp != nil else {
      throw WatchProtocolCodingError.invalidValue
    }
    guard removePlayedNativeEpisodes == nil || accountStamp != nil else {
      throw WatchProtocolCodingError.invalidValue
    }
    if let playbackRate {
      guard accountStamp != nil, playbackRate.isFinite, (0.25...4).contains(playbackRate) else {
        throw WatchProtocolCodingError.invalidValue
      }
    }
    guard version == WatchProtocolVersion.current else {
      throw WatchProtocolCodingError.unsupportedVersion(version)
    }
    guard accountStamp != nil || authenticatedAccountStamp == nil else {
      throw WatchProtocolCodingError.invalidValue
    }
    guard items.count <= WatchProtocolVersion.maxRows else {
      throw WatchProtocolCodingError.tooManyRows
    }
    guard generatedAt.timeIntervalSinceReferenceDate.isFinite else {
      throw WatchProtocolCodingError.invalidValue
    }
    for item in items { try item.validate() }
    // Keep construction bounded as well as the final encoder. The fixed allowance covers JSON
    // keys, UUID-like IDs and capability fields; the codec still checks the exact encoded bytes.
    let estimatedBytes = items.reduce(128) { total, item in
      total + item.id.utf8.count + item.title.utf8.count + (item.subtitle?.utf8.count ?? 0)
        + (item.chapterTitle?.utf8.count ?? 0) + 256
    }
    guard estimatedBytes <= WatchProtocolVersion.maxSnapshotBytes else {
      throw WatchProtocolCodingError.tooLarge
    }
    guard accountStamp != nil || (items.isEmpty && playbackState == .idle) else {
      throw WatchProtocolCodingError.invalidValue
    }
    guard Set(items.map(\.id)).count == items.count else {
      throw WatchProtocolCodingError.invalidValue
    }
  }

  public var isSignedOut: Bool {
    accountStamp == nil && items.isEmpty && playbackState == .idle
  }

  public func encode(to encoder: Encoder) throws {
    try validate()
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encodeIfPresent(accountStamp, forKey: .accountStamp)
    try container.encodeIfPresent(authenticatedAccountStamp, forKey: .authenticatedAccountStamp)
    try container.encode(playbackState, forKey: .playbackState)
    try container.encodeIfPresent(playbackRate, forKey: .playbackRate)
    try container.encodeIfPresent(skipBackwardSeconds, forKey: .skipBackwardSeconds)
    try container.encodeIfPresent(skipForwardSeconds, forKey: .skipForwardSeconds)
    try container.encodeIfPresent(playbackRatePresets, forKey: .playbackRatePresets)
    try container.encodeIfPresent(followedPodcastsEnabled, forKey: .followedPodcastsEnabled)
    try container.encodeIfPresent(removePlayedNativeEpisodes, forKey: .removePlayedNativeEpisodes)
    try container.encode(generatedAt, forKey: .generatedAt)
    try container.encode(items, forKey: .items)
  }

  private enum CodingKeys: String, CodingKey {
    // A retired `playbackLease` key from an older phone or cache is ignored.
    case version, accountStamp, authenticatedAccountStamp, playbackState, playbackRate,
      skipBackwardSeconds, skipForwardSeconds, playbackRatePresets, followedPodcastsEnabled,
      removePlayedNativeEpisodes, generatedAt, items
  }
}

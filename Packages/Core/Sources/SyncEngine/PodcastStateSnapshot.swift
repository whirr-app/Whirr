import Foundation

public struct PodcastStateSnapshot: Codable, Sendable, Equatable {
  public static let format = "com.remoteconcern.whirr.podcasts"
  public let format: String
  public let version: Int
  public let exportedAt: Date
  public let appBuild: String?
  public let globalSettings: StampedGlobalSettings
  public let subscriptions: [SubscriptionSnapshot]
  public let lastPlayed: StampedBookmark?
  public let episodeIdentities: [EpisodeIdentitySnapshot]
  public let episodes: [EpisodeSnapshot]
  /// Added after version 1 shipped: optional, so older builds ignore it and restore the rest.
  public let learnedAds: LearnedAdsSnapshot?
  /// Added after version 1 shipped, under the same rule as `learnedAds`.
  public let smartLists: PodcastSmartListsSnapshot?
  public init(
    version: Int = 1, exportedAt: Date, appBuild: String? = nil, globalSettings: StampedGlobalSettings,
    subscriptions: [SubscriptionSnapshot], lastPlayed: StampedBookmark? = nil,
    episodeIdentities: [EpisodeIdentitySnapshot], episodes: [EpisodeSnapshot],
    learnedAds: LearnedAdsSnapshot? = nil, smartLists: PodcastSmartListsSnapshot? = nil
  ) {
    self.format = Self.format
    self.version = version
    self.exportedAt = exportedAt
    self.appBuild = appBuild
    self.globalSettings = globalSettings
    self.subscriptions = subscriptions
    self.lastPlayed = lastPlayed
    self.episodeIdentities = episodeIdentities
    self.episodes = episodes
    self.learnedAds = learnedAds
    self.smartLists = smartLists
  }
}
public struct StampedGlobalSettings: Codable, Sendable, Equatable {
  public let autoDownloadEnabled: Bool
  public let keepLatestCount: Int
  public let deleteAfterPlayed: Bool
  public let allowCellularAutoDownload: Bool
  public let enabledAt: Date?
  public let showOrderMode: String
  public let writeStamp: PodcastCloudMutationStamp
  public init(
    autoDownloadEnabled: Bool, keepLatestCount: Int, deleteAfterPlayed: Bool, allowCellularAutoDownload: Bool,
    enabledAt: Date? = nil, showOrderMode: String, writeStamp: PodcastCloudMutationStamp
  ) {
    self.autoDownloadEnabled = autoDownloadEnabled
    self.keepLatestCount = keepLatestCount
    self.deleteAfterPlayed = deleteAfterPlayed
    self.allowCellularAutoDownload = allowCellularAutoDownload
    self.enabledAt = enabledAt
    self.showOrderMode = showOrderMode
    self.writeStamp = writeStamp
  }
}
public struct SubscriptionSnapshot: Codable, Sendable, Equatable {
  public let subscriptionUUID: UUID
  public let canonicalizationVersion: Int
  public let normalizedURL: String
  public let title: String
  public let author: String?
  public let subscribedAt: Date?
  public let lifecycle: PodcastCloudFollowRegister
  public let feedSettings: FeedSettingsSnapshot?
  public let customOrder: StampedCustomOrder?
  public init(
    subscriptionUUID: UUID, canonicalizationVersion: Int = 1, normalizedURL: String, title: String,
    author: String? = nil, subscribedAt: Date? = nil, lifecycle: PodcastCloudFollowRegister,
    feedSettings: FeedSettingsSnapshot? = nil, customOrder: StampedCustomOrder? = nil
  ) {
    self.subscriptionUUID = subscriptionUUID
    self.canonicalizationVersion = canonicalizationVersion
    self.normalizedURL = normalizedURL
    self.title = title
    self.author = author
    self.subscribedAt = subscribedAt
    self.lifecycle = lifecycle
    self.feedSettings = feedSettings
    self.customOrder = customOrder
  }
}
public struct StampedCustomOrder: Codable, Sendable, Equatable {
  public let value: Int?
  public let stamp: PodcastCloudMutationStamp
  public init(value: Int?, stamp: PodcastCloudMutationStamp) {
    self.value = value
    self.stamp = stamp
  }
}
public struct FeedSettingsSnapshot: Codable, Sendable, Equatable {
  public let autoDownload: String
  public let keepLatest: Int?
  public let deleteAfterPlayed: Bool?
  public let rateStep: Int?
  public let includeInLatest: Bool
  public let notificationOverride: String
  /// Nil only on a value written by a build that predates Trim Silences. Appliers keep the local
  /// setting for nil rather than resetting it, so an older device's edit to another field cannot
  /// clear it; every current writer sends the value, `inherit` included.
  public let trimSilencesOverride: String?
  /// Nil under the same rule as `trimSilencesOverride`.
  public let voiceBoostOverride: String?
  public let stamp: PodcastCloudMutationStamp
  public init(
    autoDownload: String, keepLatest: Int?, deleteAfterPlayed: Bool?, rateStep: Int?, includeInLatest: Bool,
    notificationOverride: String, trimSilencesOverride: String? = nil, voiceBoostOverride: String? = nil,
    stamp: PodcastCloudMutationStamp
  ) {
    self.autoDownload = autoDownload
    self.keepLatest = keepLatest
    self.deleteAfterPlayed = deleteAfterPlayed
    self.rateStep = rateStep
    self.includeInLatest = includeInLatest
    self.notificationOverride = notificationOverride
    self.trimSilencesOverride = trimSilencesOverride
    self.voiceBoostOverride = voiceBoostOverride
    self.stamp = stamp
  }
}
public struct EpisodeIdentitySnapshot: Codable, Sendable, Equatable {
  public let subscriptionUUID: UUID
  public let generationUUID: UUID
  public let digest: String
  public let representativeDigest: String
  public let aliases: [String]
  public let guid: String?
  public let enclosureURL: String?
  public init(
    subscriptionUUID: UUID, generationUUID: UUID, digest: String, representativeDigest: String, aliases: [String],
    guid: String? = nil, enclosureURL: String? = nil
  ) {
    self.subscriptionUUID = subscriptionUUID
    self.generationUUID = generationUUID
    self.digest = digest
    self.representativeDigest = representativeDigest
    self.aliases = aliases
    self.guid = guid
    self.enclosureURL = enclosureURL
  }
}
public struct EpisodeSnapshot: Codable, Sendable, Equatable {
  public let subscriptionUUID: UUID
  public let generationUUID: UUID
  public let representativeDigest: String
  public let identityKey: String
  public let alternateIdentityKey: String?
  public let guid: String?
  public let enclosureURL: String?
  public let title: String
  public let publishedAt: Date?
  public let duration: Double?
  public let state: EpisodeStateSnapshot?
  public let saved: PodcastCloudSavedRegister?
  public let resolution: Resolution
  public enum Resolution: String, Codable, Sendable { case resolved, pending }
  public init(
    subscriptionUUID: UUID, generationUUID: UUID, representativeDigest: String, identityKey: String,
    alternateIdentityKey: String? = nil, guid: String? = nil, enclosureURL: String? = nil, title: String,
    publishedAt: Date? = nil, duration: Double? = nil, state: EpisodeStateSnapshot? = nil,
    saved: PodcastCloudSavedRegister? = nil, resolution: Resolution
  ) {
    self.subscriptionUUID = subscriptionUUID
    self.generationUUID = generationUUID
    self.representativeDigest = representativeDigest
    self.identityKey = identityKey
    self.alternateIdentityKey = alternateIdentityKey
    self.guid = guid
    self.enclosureURL = enclosureURL
    self.title = title
    self.publishedAt = publishedAt
    self.duration = duration
    self.state = state
    self.saved = saved
    self.resolution = resolution
  }
}
public struct EpisodeStateSnapshot: Codable, Sendable, Equatable {
  public let state: PodcastCloudEpisodeState
  public let updatedAt: Date
  public init(state: PodcastCloudEpisodeState, updatedAt: Date) {
    self.state = state
    self.updatedAt = updatedAt
  }
}
public struct StampedBookmark: Codable, Sendable, Equatable {
  public let reference: EpisodeReference?
  public let writeStamp: PodcastCloudMutationStamp
  public init(reference: EpisodeReference?, writeStamp: PodcastCloudMutationStamp) {
    self.reference = reference
    self.writeStamp = writeStamp
  }
}
public struct EpisodeReference: Codable, Sendable, Equatable {
  public let subscriptionUUID: UUID
  public let generationUUID: UUID
  public let representativeDigest: String
  public init(subscriptionUUID: UUID, generationUUID: UUID, representativeDigest: String) {
    self.subscriptionUUID = subscriptionUUID
    self.generationUUID = generationUUID
    self.representativeDigest = representativeDigest
  }
}

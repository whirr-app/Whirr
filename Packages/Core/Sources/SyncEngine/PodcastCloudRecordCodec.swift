import Foundation
import Persistence

/// Snapshot-to-record mapping, generated against `PodcastCloudRecordLayout` rather than written
/// per field. The App's `CKRecord` adapter consumes `PodcastCloudRecordFields` and never sees a
/// domain type, keeping CloudKit out of `SyncEngine`. Record names are keyed forms minted by
/// `PodcastCloudIdentity`, so the caller supplies the name it resolved.
public enum PodcastCloudRecordCodec {

  // MARK: - Global settings

  public static func encode(globalSettings value: StampedGlobalSettings, recordName: String) throws
    -> PodcastCloudRecordFields
  {
    var builder = PodcastCloudRecordBuilder(
      type: PodcastCloudRecordLayout.globalSettings, recordName: recordName)
    try builder.set("autoDownloadEnabled", .boolean(value.autoDownloadEnabled))
    try builder.set("keepLatestCount", .integer(Int64(value.keepLatestCount)))
    try builder.set("deleteAfterPlayed", .boolean(value.deleteAfterPlayed))
    try builder.set("allowCellularAutoDownload", .boolean(value.allowCellularAutoDownload))
    try builder.set("enabledAt", value.enabledAt.map { .date($0) })
    try builder.set("showOrderMode", .string(value.showOrderMode))
    try builder.set(stamp: value.writeStamp, prefix: "write")
    return try builder.build()
  }

  public static func decodeGlobalSettings(_ fields: PodcastCloudRecordFields) throws
    -> StampedGlobalSettings
  {
    let reader = PodcastCloudRecordReader(
      type: PodcastCloudRecordLayout.globalSettings, fields: fields)
    try reader.validateSchema()
    guard case .boolean(let autoDownloadEnabled) = try reader.required("autoDownloadEnabled"),
      case .integer(let keepLatestCount) = try reader.required("keepLatestCount"),
      case .boolean(let deleteAfterPlayed) = try reader.required("deleteAfterPlayed"),
      case .boolean(let allowCellular) = try reader.required("allowCellularAutoDownload"),
      case .string(let showOrderMode) = try reader.required("showOrderMode")
    else { throw PodcastCloudRecordMappingError.missingRequiredField("globalSettings") }
    return StampedGlobalSettings(
      autoDownloadEnabled: autoDownloadEnabled, keepLatestCount: Int(keepLatestCount),
      deleteAfterPlayed: deleteAfterPlayed, allowCellularAutoDownload: allowCellular,
      enabledAt: try reader.date("enabledAt"), showOrderMode: showOrderMode,
      writeStamp: try reader.stamp(prefix: "write"))
  }

  // MARK: - Subscription

  /// The subscription record carries its follow register and custom-order register inline, which
  /// is why unfollowing writes this record rather than deleting it: the retired lifecycle is the
  /// content another device needs.
  public static func encode(subscription value: SubscriptionSnapshot, recordName: String) throws
    -> PodcastCloudRecordFields
  {
    var builder = PodcastCloudRecordBuilder(
      type: PodcastCloudRecordLayout.subscription, recordName: recordName)
    try builder.set("canonicalizationVersion", .integer(Int64(value.canonicalizationVersion)))
    try builder.set("normalizedURL", .string(value.normalizedURL))
    try builder.set("title", .string(value.title))
    try builder.set("author", value.author.map { .string($0) })
    try builder.set("subscribedAt", value.subscribedAt.map { .date($0) })
    try builder.set("isFollowed", .boolean(value.lifecycle.isFollowed))
    try builder.set("generationUUID", .string(value.lifecycle.generationUUID.uuidString.lowercased()))
    try builder.set(stamp: value.lifecycle.stamp, prefix: "follow")
    if let customOrder = value.customOrder {
      try builder.set("customOrder", customOrder.value.map { .integer(Int64($0)) })
      try builder.set(stamp: customOrder.stamp, prefix: "customOrder")
    }
    return try builder.build()
  }

  public static func decodeSubscription(
    _ fields: PodcastCloudRecordFields, subscriptionUUID: UUID
  ) throws -> SubscriptionSnapshot {
    let reader = PodcastCloudRecordReader(type: PodcastCloudRecordLayout.subscription, fields: fields)
    try reader.validateSchema()
    guard case .integer(let canonicalizationVersion) = try reader.required("canonicalizationVersion"),
      case .string(let normalizedURL) = try reader.required("normalizedURL"),
      case .string(let title) = try reader.required("title"),
      case .boolean(let isFollowed) = try reader.required("isFollowed"),
      case .string(let generation) = try reader.required("generationUUID"),
      let generationUUID = UUID(uuidString: generation)
    else { throw PodcastCloudRecordMappingError.missingRequiredField("subscription") }

    var customOrder: StampedCustomOrder?
    if let stamp = try? reader.stamp(prefix: "customOrder") {
      customOrder = StampedCustomOrder(
        value: try reader.integer("customOrder").map(Int.init), stamp: stamp)
    }
    return SubscriptionSnapshot(
      subscriptionUUID: subscriptionUUID, canonicalizationVersion: Int(canonicalizationVersion),
      normalizedURL: normalizedURL, title: title, author: try reader.string("author"),
      subscribedAt: try reader.date("subscribedAt"),
      lifecycle: PodcastCloudFollowRegister(
        subscriptionUUID: subscriptionUUID, generationUUID: generationUUID, isFollowed: isFollowed,
        stamp: try reader.stamp(prefix: "follow")),
      customOrder: customOrder)
  }

  // MARK: - Feed settings

  public static func encode(feedSettings value: FeedSettingsSnapshot, recordName: String) throws
    -> PodcastCloudRecordFields
  {
    var builder = PodcastCloudRecordBuilder(
      type: PodcastCloudRecordLayout.feedSettings, recordName: recordName)
    try builder.set("autoDownload", .string(value.autoDownload))
    try builder.set("keepLatest", value.keepLatest.map { .integer(Int64($0)) })
    try builder.set("deleteAfterPlayed", value.deleteAfterPlayed.map { .boolean($0) })
    try builder.set("rateStep", value.rateStep.map { .integer(Int64($0)) })
    try builder.set("includeInLatest", .boolean(value.includeInLatest))
    try builder.set("notificationOverride", .string(value.notificationOverride))
    try builder.set("trimSilencesOverride", value.trimSilencesOverride.map { .string($0) })
    try builder.set("voiceBoostOverride", value.voiceBoostOverride.map { .string($0) })
    try builder.set(stamp: value.stamp, prefix: "write")
    return try builder.build()
  }

  public static func decodeFeedSettings(_ fields: PodcastCloudRecordFields) throws
    -> FeedSettingsSnapshot
  {
    let reader = PodcastCloudRecordReader(type: PodcastCloudRecordLayout.feedSettings, fields: fields)
    try reader.validateSchema()
    guard case .string(let autoDownload) = try reader.required("autoDownload"),
      case .boolean(let includeInLatest) = try reader.required("includeInLatest"),
      case .string(let notificationOverride) = try reader.required("notificationOverride")
    else { throw PodcastCloudRecordMappingError.missingRequiredField("feedSettings") }
    return FeedSettingsSnapshot(
      autoDownload: autoDownload, keepLatest: try reader.integer("keepLatest").map(Int.init),
      deleteAfterPlayed: try reader.boolean("deleteAfterPlayed"),
      rateStep: try reader.integer("rateStep").map(Int.init), includeInLatest: includeInLatest,
      notificationOverride: notificationOverride,
      // A value this build does not know (from a newer build) reads as absent, so the applier
      // keeps the local setting instead of writing something the column's CHECK would refuse.
      trimSilencesOverride: try reader.string("trimSilencesOverride")
        .flatMap { TrimSilencesShowOverride(rawValue: $0)?.rawValue },
      voiceBoostOverride: try reader.string("voiceBoostOverride")
        .flatMap { VoiceBoostShowOverride(rawValue: $0)?.rawValue },
      stamp: try reader.stamp(prefix: "write"))
  }

  // MARK: - Episode state

  /// `identityKey` and the alias fields travel with the state so a receiving device can resolve
  /// the episode even when its own feed copy has already dropped it.
  public static func encode(
    episodeState value: PodcastCloudEpisodeState, identity: PodcastCloudEpisodeIdentityFields,
    recordName: String
  ) throws -> PodcastCloudRecordFields {
    var builder = PodcastCloudRecordBuilder(
      type: PodcastCloudRecordLayout.episodeState, recordName: recordName)
    try builder.set("identityKey", .string(identity.identityKey))
    try builder.set("alternateIdentityKey", identity.alternateIdentityKey.map { .string($0) })
    try builder.set("guid", identity.guid.map { .string($0) })
    try builder.set("enclosureURL", identity.enclosureURL.map { .string($0) })
    try builder.set("aliases", identity.aliases.isEmpty ? nil : .stringList(identity.aliases))
    try builder.set("title", identity.title.map { .string($0) })
    try builder.set("publishedAt", identity.publishedAt.map { .date($0) })
    try builder.set("duration", identity.duration.map { .double($0) })
    try builder.set("position", .double(value.position))
    try builder.set("isFinished", .boolean(value.isFinished))
    try builder.set("isDismissed", .boolean(value.isDismissed))
    try builder.set("updatedAt", identity.updatedAt.map { .date($0) })
    try builder.set(stamp: value.explicitEpoch, prefix: "explicitEpoch")
    try builder.set(stamp: value.writeStamp, prefix: "write")
    return try builder.build()
  }

  public static func decodeEpisodeState(_ fields: PodcastCloudRecordFields) throws
    -> (state: PodcastCloudEpisodeState, identity: PodcastCloudEpisodeIdentityFields)
  {
    let reader = PodcastCloudRecordReader(type: PodcastCloudRecordLayout.episodeState, fields: fields)
    try reader.validateSchema()
    guard case .double(let position) = try reader.required("position"),
      case .boolean(let isFinished) = try reader.required("isFinished"),
      case .boolean(let isDismissed) = try reader.required("isDismissed"),
      case .string(let identityKey) = try reader.required("identityKey")
    else { throw PodcastCloudRecordMappingError.missingRequiredField("episodeState") }
    let state = try PodcastCloudEpisodeState(
      position: position, isFinished: isFinished, isDismissed: isDismissed,
      explicitEpoch: try reader.stamp(prefix: "explicitEpoch"),
      writeStamp: try reader.stamp(prefix: "write"))
    let identity = PodcastCloudEpisodeIdentityFields(
      identityKey: identityKey, alternateIdentityKey: try reader.string("alternateIdentityKey"),
      guid: try reader.string("guid"), enclosureURL: try reader.string("enclosureURL"),
      aliases: try reader.stringList("aliases") ?? [], title: try reader.string("title"),
      publishedAt: try reader.date("publishedAt"), duration: try reader.double("duration"),
      updatedAt: try reader.date("updatedAt"))
    return (state, identity)
  }

  // MARK: - Saved register

  public static func encode(
    savedRegister value: PodcastCloudSavedRegister, identity: PodcastCloudEpisodeIdentityFields,
    recordName: String
  ) throws -> PodcastCloudRecordFields {
    var builder = PodcastCloudRecordBuilder(
      type: PodcastCloudRecordLayout.savedEpisode, recordName: recordName)
    try builder.set("identityKey", .string(identity.identityKey))
    try builder.set("alternateIdentityKey", identity.alternateIdentityKey.map { .string($0) })
    try builder.set("guid", identity.guid.map { .string($0) })
    try builder.set("enclosureURL", identity.enclosureURL.map { .string($0) })
    try builder.set("aliases", identity.aliases.isEmpty ? nil : .stringList(identity.aliases))
    try builder.set("isSaved", .boolean(value.isSaved))
    try builder.set("savedAt", value.savedAt.map { .date($0) })
    try builder.set(stamp: value.stamp, prefix: "saved")
    return try builder.build()
  }

  public static func decodeSavedRegister(_ fields: PodcastCloudRecordFields) throws
    -> PodcastCloudSavedRegister
  {
    let reader = PodcastCloudRecordReader(type: PodcastCloudRecordLayout.savedEpisode, fields: fields)
    try reader.validateSchema()
    guard case .boolean(let isSaved) = try reader.required("isSaved") else {
      throw PodcastCloudRecordMappingError.missingRequiredField("isSaved")
    }
    return try PodcastCloudSavedRegister(
      isSaved: isSaved, savedAt: try reader.date("savedAt"), stamp: try reader.stamp(prefix: "saved"))
  }

  /// The saved register with the identity evidence it carries, for resolving which local episode
  /// it names.
  public static func decodeSavedEpisode(_ fields: PodcastCloudRecordFields) throws
    -> (register: PodcastCloudSavedRegister, identity: PodcastCloudEpisodeIdentityFields)
  {
    let register = try decodeSavedRegister(fields)
    let reader = PodcastCloudRecordReader(type: PodcastCloudRecordLayout.savedEpisode, fields: fields)
    guard case .string(let identityKey) = try reader.required("identityKey") else {
      throw PodcastCloudRecordMappingError.missingRequiredField("identityKey")
    }
    return (
      register,
      PodcastCloudEpisodeIdentityFields(
        identityKey: identityKey, alternateIdentityKey: try reader.string("alternateIdentityKey"),
        guid: try reader.string("guid"), enclosureURL: try reader.string("enclosureURL"),
        aliases: try reader.stringList("aliases") ?? [])
    )
  }

  // MARK: - Last played

  /// A cleared bookmark is the register with no reference, not a missing record, so a clear can be
  /// ordered against another device's newer play.
  public static func encode(bookmark value: StampedBookmark, recordName: String) throws
    -> PodcastCloudRecordFields
  {
    var builder = PodcastCloudRecordBuilder(type: PodcastCloudRecordLayout.lastPlayed, recordName: recordName)
    try builder.set(
      "subscriptionUUID", value.reference.map { .string($0.subscriptionUUID.uuidString.lowercased()) })
    try builder.set("generationUUID", value.reference.map { .string($0.generationUUID.uuidString.lowercased()) })
    try builder.set("representativeDigest", value.reference.map { .string($0.representativeDigest) })
    try builder.set(stamp: value.writeStamp, prefix: "write")
    return try builder.build()
  }

  public static func decodeBookmark(_ fields: PodcastCloudRecordFields) throws -> StampedBookmark {
    let reader = PodcastCloudRecordReader(type: PodcastCloudRecordLayout.lastPlayed, fields: fields)
    try reader.validateSchema()
    var reference: EpisodeReference?
    if let subscription = try reader.string("subscriptionUUID") {
      guard let subscriptionUUID = UUID(uuidString: subscription),
        let generation = try reader.string("generationUUID"),
        let generationUUID = UUID(uuidString: generation),
        let digest = try reader.string("representativeDigest")
      else { throw PodcastCloudRecordMappingError.missingRequiredField("lastPlayed") }
      reference = EpisodeReference(
        subscriptionUUID: subscriptionUUID, generationUUID: generationUUID, representativeDigest: digest)
    }
    return StampedBookmark(reference: reference, writeStamp: try reader.stamp(prefix: "write"))
  }

  // MARK: - Keyring

  public static func encodeKeyring(recordNameKey: Data) throws -> PodcastCloudRecordFields {
    var builder = PodcastCloudRecordBuilder(
      type: PodcastCloudRecordLayout.keyring, recordName: PodcastCloudIdentity.keyringRecordName)
    try builder.set(PodcastCloudRecordLayout.recordNameKeyFieldName, .data(recordNameKey))
    return try builder.build()
  }

  public static func decodeKeyring(_ fields: PodcastCloudRecordFields) throws -> Data {
    let reader = PodcastCloudRecordReader(type: PodcastCloudRecordLayout.keyring, fields: fields)
    try reader.validateSchema()
    guard case .data(let key) = try reader.required(PodcastCloudRecordLayout.recordNameKeyFieldName)
    else {
      throw PodcastCloudRecordMappingError.missingRequiredField(
        PodcastCloudRecordLayout.recordNameKeyFieldName)
    }
    return key
  }
}

/// The identity and metadata an episode record carries alongside its register. Kept separate from
/// `PodcastCloudEpisodeState` because the state is the merged intent while these are the evidence
/// used to resolve which episode the intent belongs to.
public struct PodcastCloudEpisodeIdentityFields: Sendable, Equatable {
  public let identityKey: String
  public let alternateIdentityKey: String?
  public let guid: String?
  public let enclosureURL: String?
  public let aliases: [String]
  public let title: String?
  public let publishedAt: Date?
  public let duration: Double?
  public let updatedAt: Date?

  public init(
    identityKey: String, alternateIdentityKey: String? = nil, guid: String? = nil,
    enclosureURL: String? = nil, aliases: [String] = [], title: String? = nil,
    publishedAt: Date? = nil, duration: Double? = nil, updatedAt: Date? = nil
  ) {
    self.identityKey = identityKey
    self.alternateIdentityKey = alternateIdentityKey
    self.guid = guid
    self.enclosureURL = enclosureURL
    self.aliases = aliases
    self.title = title
    self.publishedAt = publishedAt
    self.duration = duration
    self.updatedAt = updatedAt
  }
}

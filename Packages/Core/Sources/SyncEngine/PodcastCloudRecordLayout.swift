import Foundation

/// The single inventory of V1 `PodcastState` record types and their fields, with the encryption
/// decision per field. The App's `CKRecord` mapping must be generated from this table and must
/// write every `isEncrypted` field through `CKRecord.encryptedValues`.
///
/// Each record has one plaintext field, the integer `schema` marker; everything else is encrypted
/// so Advanced Data Protection covers it. Field names must not carry values, and no field may be a
/// `CKRecord.Reference` or `CKAsset` (not encryptable). Encrypted fields must be declared as such
/// when first created in the Development schema; a plaintext field can only be replaced under a
/// new name. The keyring has no mutation stamp: written once, never merged, only the mint race
/// conflicts.
public enum PodcastCloudRecordLayout {
  public static let schemaFieldName = "schema"
  public static let recordNameKeyFieldName = "recordNameKey"
  public static let schemaVersion = 1

  public enum ValueKind: String, Sendable, Equatable {
    case string, integer, boolean, double, date, data, stringList
  }

  public struct Field: Sendable, Equatable {
    public let name: String
    public let kind: ValueKind
    public let isEncrypted: Bool

    public init(name: String, kind: ValueKind, isEncrypted: Bool) {
      self.name = name
      self.kind = kind
      self.isEncrypted = isEncrypted
    }
  }

  public struct RecordType: Sendable, Equatable {
    public let name: String
    /// The `PodcastCloudIdentity.recordName(kind:components:)` kind that names its records.
    public let identityKind: String
    public let fields: [Field]

    public var plaintextFieldNames: [String] {
      fields.filter { $0.isEncrypted == false }.map(\.name)
    }
  }

  private static let schema = Field(name: schemaFieldName, kind: .integer, isEncrypted: false)

  private static func stamp(_ prefix: String) -> [Field] {
    [
      Field(name: "\(prefix)PhysicalMilliseconds", kind: .integer, isEncrypted: true),
      Field(name: "\(prefix)LogicalCounter", kind: .integer, isEncrypted: true),
      Field(name: "\(prefix)InstallationUUID", kind: .string, isEncrypted: true),
      Field(name: "\(prefix)MutationUUID", kind: .string, isEncrypted: true),
    ]
  }

  private static func identityFields() -> [Field] {
    [
      Field(name: "identityKey", kind: .string, isEncrypted: true),
      Field(name: "alternateIdentityKey", kind: .string, isEncrypted: true),
      Field(name: "guid", kind: .string, isEncrypted: true),
      Field(name: "enclosureURL", kind: .string, isEncrypted: true),
      Field(name: "aliases", kind: .stringList, isEncrypted: true),
    ]
  }

  /// Mirrors `SubscriptionSnapshot` plus its follow register and custom-order register.
  public static let subscription = RecordType(
    name: "PodcastSubscription", identityKind: "sub",
    fields: [schema]
      + [
        Field(name: "canonicalizationVersion", kind: .integer, isEncrypted: true),
        Field(name: "normalizedURL", kind: .string, isEncrypted: true),
        Field(name: "title", kind: .string, isEncrypted: true),
        Field(name: "author", kind: .string, isEncrypted: true),
        Field(name: "subscribedAt", kind: .date, isEncrypted: true),
        Field(name: "isFollowed", kind: .boolean, isEncrypted: true),
        Field(name: "generationUUID", kind: .string, isEncrypted: true),
      ] + stamp("follow")
      + [Field(name: "customOrder", kind: .integer, isEncrypted: true)] + stamp("customOrder"))

  /// Mirrors `FeedSettingsSnapshot`.
  public static let feedSettings = RecordType(
    name: "PodcastFeedSettings", identityKind: "settings",
    fields: [schema]
      + [
        Field(name: "autoDownload", kind: .string, isEncrypted: true),
        Field(name: "keepLatest", kind: .integer, isEncrypted: true),
        Field(name: "deleteAfterPlayed", kind: .boolean, isEncrypted: true),
        Field(name: "rateStep", kind: .integer, isEncrypted: true),
        Field(name: "includeInLatest", kind: .boolean, isEncrypted: true),
        Field(name: "notificationOverride", kind: .string, isEncrypted: true),
        // Added after schema version 1 shipped: optional, so older readers ignore them.
        Field(name: "trimSilencesOverride", kind: .string, isEncrypted: true),
        Field(name: "voiceBoostOverride", kind: .string, isEncrypted: true),
      ] + stamp("write"))

  /// Mirrors `EpisodeSnapshot` metadata and `PodcastCloudEpisodeState`.
  public static let episodeState = RecordType(
    name: "PodcastEpisodeState", identityKind: "state",
    fields: [schema] + identityFields()
      + [
        Field(name: "title", kind: .string, isEncrypted: true),
        Field(name: "publishedAt", kind: .date, isEncrypted: true),
        Field(name: "duration", kind: .double, isEncrypted: true),
        Field(name: "position", kind: .double, isEncrypted: true),
        Field(name: "isFinished", kind: .boolean, isEncrypted: true),
        Field(name: "isDismissed", kind: .boolean, isEncrypted: true),
        Field(name: "updatedAt", kind: .date, isEncrypted: true),
      ] + stamp("explicitEpoch") + stamp("write"))

  /// Mirrors `EpisodeIdentitySnapshot`.
  public static let episodeIdentity = RecordType(
    name: "PodcastEpisodeIdentity", identityKind: "identity",
    fields: [schema]
      + [
        Field(name: "representativeDigest", kind: .string, isEncrypted: true),
        Field(name: "aliases", kind: .stringList, isEncrypted: true),
        Field(name: "guid", kind: .string, isEncrypted: true),
        Field(name: "enclosureURL", kind: .string, isEncrypted: true),
      ] + stamp("write"))

  /// Mirrors `EpisodeSnapshot` identity plus `PodcastCloudSavedRegister`.
  public static let savedEpisode = RecordType(
    name: "PodcastSavedEpisode", identityKind: "saved",
    fields: [schema] + identityFields()
      + [
        Field(name: "isSaved", kind: .boolean, isEncrypted: true),
        Field(name: "savedAt", kind: .date, isEncrypted: true),
      ] + stamp("saved"))

  /// Mirrors `StampedGlobalSettings`.
  public static let globalSettings = RecordType(
    name: "PodcastGlobalSettings", identityKind: "globals",
    fields: [schema]
      + [
        Field(name: "autoDownloadEnabled", kind: .boolean, isEncrypted: true),
        Field(name: "keepLatestCount", kind: .integer, isEncrypted: true),
        Field(name: "deleteAfterPlayed", kind: .boolean, isEncrypted: true),
        Field(name: "allowCellularAutoDownload", kind: .boolean, isEncrypted: true),
        Field(name: "enabledAt", kind: .date, isEncrypted: true),
        Field(name: "showOrderMode", kind: .string, isEncrypted: true),
      ] + stamp("write"))

  /// Mirrors `StampedBookmark`/`EpisodeReference`.
  public static let lastPlayed = RecordType(
    name: "PodcastLastPlayed", identityKind: "bookmark",
    fields: [schema]
      + [
        Field(name: "subscriptionUUID", kind: .string, isEncrypted: true),
        Field(name: "generationUUID", kind: .string, isEncrypted: true),
        Field(name: "representativeDigest", kind: .string, isEncrypted: true),
      ] + stamp("write"))

  public static let keyring = RecordType(
    name: "PodcastKeyring", identityKind: "keyring",
    fields: [schema, Field(name: recordNameKeyFieldName, kind: .data, isEncrypted: true)])

  public static let allRecordTypes: [RecordType] = [
    subscription, feedSettings, episodeState, episodeIdentity, savedEpisode, globalSettings,
    lastPlayed, keyring,
  ]

  /// Names that a plaintext audit may find; anything else in a record's plaintext key set is a
  /// defect in the mapping, not a schema decision.
  public static let permittedPlaintextFieldNames: Set<String> = [schemaFieldName]

  /// The layout entry for a record type name, or `nil` for a type this version does not declare.
  ///
  /// The App's `CKRecord` translation reads through this, not the record's key list, so a field a
  /// newer schema adds is ignored and an encrypted field is read only from the encrypted
  /// compartment.
  public static func recordType(named name: String) -> RecordType? {
    allRecordTypes.first { $0.name == name }
  }
}

import ABSApi
import Foundation
import Persistence

/// The bounded field names a command reader may reject. It carries no value, so a
/// malformed feed cannot make a URL, credential, title, or synopsis appear in an error/log.
public enum NativeEpisodeServerSaveCommandField: String, Codable, Sendable, Equatable {
  case feedURL
  case enclosureURL
  case feedTitle
  case feedAuthor
  case feedSynopsis
  case episodeIdentityKey
  case episodeGUID
  case episodeTitle
  case episodeSynopsis
  case enclosureType
}

/// Privacy-safe failures while assembling one server-save command from the persisted native RSS
/// subscription. Raw records, Keychain errors, URLs, and feed metadata never escape this enum.
public enum NativeEpisodeServerSaveCommandReaderError: Error, Sendable, Equatable,
  CustomStringConvertible
{
  case invalidIdentity
  case nativeSubscriptionsDisabled
  case feedNotFound
  case episodeNotFound
  case episodeNotInFeed
  case invalidFeedURL(ServerConfigurationIssue)
  case invalidEnclosureURL(ServerConfigurationIssue)
  case credentialedFeed
  case credentialStoreUnavailable
  case missingFeedTitle
  case fieldTooLong(NativeEpisodeServerSaveCommandField)

  public var description: String {
    switch self {
    case .invalidIdentity:
      return "The native episode identity is invalid."
    case .nativeSubscriptionsDisabled:
      return "Native podcast subscriptions are disabled."
    case .feedNotFound:
      return "The native podcast subscription was not found."
    case .episodeNotFound:
      return "The native podcast episode was not found."
    case .episodeNotInFeed:
      return "The native episode is not part of that subscription."
    case .invalidFeedURL(let issue):
      return "The stored feed URL is invalid (\(Self.configurationIssueDescription(issue)))."
    case .invalidEnclosureURL(let issue):
      return "The stored enclosure URL is invalid (\(Self.configurationIssueDescription(issue)))."
    case .credentialedFeed:
      return "This native feed uses device-held credentials and cannot be copied to the server."
    case .credentialStoreUnavailable:
      return "The native feed credential state could not be checked."
    case .missingFeedTitle:
      return "The native feed has no usable title."
    case .fieldTooLong(let field):
      return "The stored native episode field \(field.rawValue) is too long."
    }
  }

  private static func configurationIssueDescription(_ issue: ServerConfigurationIssue) -> String {
    switch issue {
    case .unsupportedScheme: return "unsupported scheme"
    case .missingHost: return "missing host"
    case .credentialsNotAllowed: return "credentials not allowed"
    case .queryNotAllowed: return "query not allowed"
    case .fragmentNotAllowed: return "fragment not allowed"
    case .pathTraversalNotAllowed: return "path traversal not allowed"
    }
  }
}

/// Bounded metadata and the validated source enclosure needed by NP12's later ABSApi payload
/// builder. The URL fields are `internal`: AppModel can carry only this value's
/// opaque ids and bounded metadata through a public protocol, while the SyncEngine wire owner
/// can still assemble a request inside this target. `description` and `debugDescription` are
/// hand-written so accidental diagnostics cannot print the source URLs or user content.
public struct NativeEpisodeServerSaveCommand: Sendable, Equatable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  public let feedId: Int64
  public let episodeId: Int64
  public let episodeIdentityKey: String
  public let feedTitle: String
  public let feedAuthor: String?
  public let feedSynopsis: String?
  public let episodeGUID: String?
  public let episodeTitle: String?
  public let episodeSynopsis: String?
  public let enclosureType: String?
  public let declaredBytes: Int64?
  public let durationSeconds: Double?
  public let seasonNumber: Int?
  public let episodeNumber: Int?
  public let publishedAt: Date?

  // These are source-only values. They are not public API and are not included in descriptions.
  let feedURL: URL
  let feedArtworkURL: URL?
  let enclosureURL: URL

  init(
    feedId: Int64,
    episodeId: Int64,
    episodeIdentityKey: String,
    feedTitle: String,
    feedAuthor: String?,
    feedSynopsis: String?,
    episodeGUID: String?,
    episodeTitle: String?,
    episodeSynopsis: String?,
    enclosureType: String?,
    declaredBytes: Int64?,
    durationSeconds: Double?,
    seasonNumber: Int?,
    episodeNumber: Int?,
    publishedAt: Date?,
    feedURL: URL,
    enclosureURL: URL,
    feedArtworkURL: URL? = nil
  ) {
    self.feedId = feedId
    self.episodeId = episodeId
    self.episodeIdentityKey = episodeIdentityKey
    self.feedTitle = feedTitle
    self.feedAuthor = feedAuthor
    self.feedSynopsis = feedSynopsis
    self.episodeGUID = episodeGUID
    self.episodeTitle = episodeTitle
    self.episodeSynopsis = episodeSynopsis
    self.enclosureType = enclosureType
    self.declaredBytes = declaredBytes
    self.durationSeconds = durationSeconds
    self.seasonNumber = seasonNumber
    self.episodeNumber = episodeNumber
    self.publishedAt = publishedAt
    self.feedURL = feedURL
    self.feedArtworkURL = feedArtworkURL
    self.enclosureURL = enclosureURL
  }

  public var description: String {
    "NativeEpisodeServerSaveCommand(feedId: \(feedId), episodeId: \(episodeId), "
      + "identity: <redacted>, hasAuthor: \(feedAuthor != nil), hasSynopsis: \(feedSynopsis != nil), "
      + "hasArtwork: \(feedArtworkURL != nil), hasEnclosure: true)"
  }

  /// Source URLs are not diagnostic data. Suppress synthesized reflection so a failed assertion
  /// cannot print either value.
  public var customMirror: Mirror { Mirror(self, unlabeledChildren: []) }

  public var debugDescription: String { description }
}

/// Dependency-correct command boundary. Persistence owns the RSS records; SyncEngine owns the
/// Keychain adapter and the native-subscription preference, so this reader composes both without
/// making Persistence depend upward on ABSApi or AppModel.
public protocol NativeEpisodeServerSaveCommandReading: Sendable {
  func read(feedId: Int64, episodeId: Int64) async throws -> NativeEpisodeServerSaveCommand
}

/// Reads exactly one currently subscribed RSS episode and projects the bounded values the later
/// serialized coordinator may send. It performs all eligibility checks on every read so a stale
/// card cannot bypass an unsubscribe, toggle-off, URL, or Keychain decision.
public struct PersistenceNativeEpisodeServerSaveCommandReader:
  NativeEpisodeServerSaveCommandReading, Sendable
{
  /// The RSS parser's ingress cap is 16 KiB. Persisted rows can predate that cap or be modified by
  /// a future importer, so this command boundary re-applies it before any value reaches ABSApi.
  public static let maximumStringBytes = PodcastWriteBounds.maximumStringBytes
  /// Stable identity keys are tighter than descriptive metadata and match the v51
  /// attempt-table bound.
  public static let maximumIdentityBytes = 512

  private let database: AppDatabase
  private let feedCredentialStore: any FeedCredentialStoring
  private let nativeSubscriptions: any NativePodcastSubscriptionsReading

  public init(
    database: AppDatabase,
    feedCredentialStore: any FeedCredentialStoring,
    nativeSubscriptions: any NativePodcastSubscriptionsReading
  ) {
    self.database = database
    self.feedCredentialStore = feedCredentialStore
    self.nativeSubscriptions = nativeSubscriptions
  }

  public func read(feedId: Int64, episodeId: Int64) async throws -> NativeEpisodeServerSaveCommand {
    guard feedId > 0, episodeId > 0 else {
      throw NativeEpisodeServerSaveCommandReaderError.invalidIdentity
    }
    guard await nativeSubscriptions.isEnabled() else {
      throw NativeEpisodeServerSaveCommandReaderError.nativeSubscriptionsDisabled
    }

    let records = try await database.readAsync { db -> (RSSFeedRecord, RSSEpisodeRecord) in
      guard let feed = try RSSFeedRecord.fetchOne(db, key: feedId) else {
        throw NativeEpisodeServerSaveCommandReaderError.feedNotFound
      }
      guard let episode = try RSSEpisodeRecord.fetchOne(db, key: episodeId) else {
        throw NativeEpisodeServerSaveCommandReaderError.episodeNotFound
      }
      guard episode.feedId == feedId else {
        throw NativeEpisodeServerSaveCommandReaderError.episodeNotInFeed
      }
      return (feed, episode)
    }

    let feedURL = try Self.validatedURL(
      records.0.feedURL, field: .feedURL,
      invalid: NativeEpisodeServerSaveCommandReaderError.invalidFeedURL)
    let enclosureURL = try Self.validatedURL(
      records.1.enclosureURL, field: .enclosureURL,
      invalid: NativeEpisodeServerSaveCommandReaderError.invalidEnclosureURL)
    // Artwork is an optional persisted declaration. Revalidate it independently at this boundary;
    // legacy rows may predate the stricter RSSFeedStore ingress filter. A rejected declaration must
    // never make the required feed/episode command fail.
    let feedArtworkURL: URL? = records.0.artworkURL.flatMap { rawValue in
      guard let validated = PodcastCreateRequest.validatedImageURL(rawValue) else { return nil }
      return URL(string: validated)
    }

    do {
      if try feedCredentialStore.load(forFeedID: feedId) != nil {
        throw NativeEpisodeServerSaveCommandReaderError.credentialedFeed
      }
    } catch let error as NativeEpisodeServerSaveCommandReaderError {
      throw error
    } catch {
      // Keychain implementation errors are collapsed; the source error could carry
      // account/service details and must never become part of the command boundary or diagnostics.
      throw NativeEpisodeServerSaveCommandReaderError.credentialStoreUnavailable
    }

    let feedTitle = try Self.requiredString(records.0.title, field: .feedTitle)
    let feedAuthor = try Self.optionalString(records.0.author, field: .feedAuthor)
    let feedSynopsis = try Self.optionalString(records.0.synopsis, field: .feedSynopsis)
    guard records.1.identityKey.isEmpty == false,
      records.1.identityKey.utf8.count <= Self.maximumIdentityBytes,
      records.1.identityKey.utf8.allSatisfy({ $0 != 0 })
    else {
      throw NativeEpisodeServerSaveCommandReaderError.fieldTooLong(.episodeIdentityKey)
    }

    return NativeEpisodeServerSaveCommand(
      feedId: feedId,
      episodeId: episodeId,
      episodeIdentityKey: records.1.identityKey,
      feedTitle: feedTitle,
      feedAuthor: feedAuthor,
      feedSynopsis: feedSynopsis,
      episodeGUID: try Self.optionalString(
        records.1.guid, field: .episodeGUID, maximumBytes: Self.maximumIdentityBytes),
      episodeTitle: try Self.optionalString(records.1.title, field: .episodeTitle),
      episodeSynopsis: try Self.optionalString(records.1.synopsis, field: .episodeSynopsis),
      enclosureType: try Self.optionalString(records.1.enclosureType, field: .enclosureType),
      declaredBytes: records.1.declaredBytes.flatMap { $0 > 0 ? $0 : nil },
      durationSeconds: records.1.durationSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
      seasonNumber: records.1.seasonNumber,
      episodeNumber: records.1.episodeNumber,
      publishedAt: records.1.publishedAt.flatMap { date in
        let epoch = date.timeIntervalSince1970
        return epoch.isFinite && epoch >= 0 ? date : nil
      },
      feedURL: feedURL,
      enclosureURL: enclosureURL,
      feedArtworkURL: feedArtworkURL)
  }

  private static func requiredString(
    _ value: String?, field: NativeEpisodeServerSaveCommandField
  ) throws -> String {
    guard let value else {
      if field == .feedTitle {
        throw NativeEpisodeServerSaveCommandReaderError.missingFeedTitle
      }
      throw NativeEpisodeServerSaveCommandReaderError.fieldTooLong(field)
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else {
      if field == .feedTitle {
        throw NativeEpisodeServerSaveCommandReaderError.missingFeedTitle
      }
      throw NativeEpisodeServerSaveCommandReaderError.fieldTooLong(field)
    }
    guard value.utf8.count <= Self.maximumStringBytes,
      value.utf8.allSatisfy({ $0 != 0 })
    else { throw NativeEpisodeServerSaveCommandReaderError.fieldTooLong(field) }
    return value
  }

  private static func optionalString(
    _ value: String?,
    field: NativeEpisodeServerSaveCommandField,
    maximumBytes: Int = Self.maximumStringBytes
  ) throws -> String? {
    guard let value else { return nil }
    guard value.isEmpty == false else { return nil }
    guard value.utf8.count <= maximumBytes, value.utf8.allSatisfy({ $0 != 0 }) else {
      throw NativeEpisodeServerSaveCommandReaderError.fieldTooLong(field)
    }
    return value
  }

  private static func validatedURL(
    _ rawValue: String,
    field: NativeEpisodeServerSaveCommandField,
    invalid: (ServerConfigurationIssue) -> NativeEpisodeServerSaveCommandReaderError
  ) throws -> URL {
    guard rawValue.utf8.count <= Self.maximumStringBytes,
      rawValue.utf8.allSatisfy({ $0 != 0 })
    else { throw NativeEpisodeServerSaveCommandReaderError.fieldTooLong(field) }
    guard let url = URL(string: rawValue) else {
      throw invalid(.missingHost)
    }
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      throw invalid(.unsupportedScheme)
    }
    guard let host = url.host, host.isEmpty == false else {
      throw invalid(.missingHost)
    }
    guard url.user == nil, url.password == nil else {
      throw invalid(.credentialsNotAllowed)
    }
    return url
  }
}

/// Shorter spelling for callers that do not need to name the Persistence composition detail.
public typealias NativeEpisodeServerSaveCommandReader =
  PersistenceNativeEpisodeServerSaveCommandReader

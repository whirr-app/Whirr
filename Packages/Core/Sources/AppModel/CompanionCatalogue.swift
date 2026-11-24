import CryptoKit
import Foundation
import Persistence

/// The fixed shelves exported by the phone-side Watch catalogue projection.
///
/// An AppModel value, not a wire model: the WatchProtocol package owns the wire representation and
/// the phone bridge maps this value at that boundary, keeping Persistence identity and
/// file-backed download details out of the protocol target.
public enum CompanionCatalogueSection: String, CaseIterable, Sendable, Equatable {
  case continueListening
  case recentBooks
  case recentEpisodes
  case downloads
}

/// Playback and destination facts for one row. An Audiobookshelf row is Watch-playable because
/// the Watch streams it from the server with its own credentials; a native episode is phone-owned
/// and its local file never implies Watch availability. `watchDownloaded` is reserved for a
/// future Watch-owned download projection and is therefore always false in this phase.
public struct CompanionCatalogueCapabilities: Sendable, Equatable {
  public let phonePlayable: Bool
  public let watchPlayable: Bool
  public let phoneDownloaded: Bool
  public let watchDownloaded: Bool

  public init(
    phonePlayable: Bool,
    watchPlayable: Bool,
    phoneDownloaded: Bool = false,
    watchDownloaded: Bool = false
  ) {
    self.phonePlayable = phonePlayable
    self.watchPlayable = watchPlayable
    self.phoneDownloaded = phoneDownloaded
    self.watchDownloaded = watchDownloaded
  }
}

/// Safe, text-bounded metadata for a single Watch shelf row. It has no URL, file
/// path, credential, server capability, or playback-session field.
public struct CompanionCatalogueItem: Sendable, Equatable, Identifiable {
  public let id: CompanionSelection
  public let title: String
  public let subtitle: String?
  public let progressSeconds: Double
  public let durationSeconds: Double?
  public let capabilities: CompanionCatalogueCapabilities
  public let isCurrentPlayback: Bool
  /// The server `updatedAt` of the book or show whose cover this row draws, so the Watch can
  /// address that cover by revision. Nil for native feeds and rows the phone cannot date.
  public let serverUpdatedAt: Date?

  public init(
    id: CompanionSelection,
    title: String,
    subtitle: String? = nil,
    progressSeconds: Double = 0,
    durationSeconds: Double? = nil,
    capabilities: CompanionCatalogueCapabilities,
    isCurrentPlayback: Bool = false,
    serverUpdatedAt: Date? = nil
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.progressSeconds = progressSeconds
    self.durationSeconds = durationSeconds
    self.capabilities = capabilities
    self.isCurrentPlayback = isCurrentPlayback
    self.serverUpdatedAt = serverUpdatedAt
  }
}

/// A schema-versioned, account-fenced, phone-owned catalogue snapshot. The section order is
/// stable and fixed to the four supported shelves.
public struct CompanionCatalogueSnapshot: Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  /// SHA-256 of the local account id, client UUID, and server identity fingerprint. The raw
  /// values never leave AppModel, and a missing identity produces a signed-out empty snapshot.
  public let accountServerIdentityHash: String?
  public let accountIdentityHash: String?
  public let serverIdentityHash: String?
  public let continueListening: [CompanionCatalogueItem]
  public let recentBooks: [CompanionCatalogueItem]
  public let recentEpisodes: [CompanionCatalogueItem]
  public let downloads: [CompanionCatalogueItem]

  public init(
    schemaVersion: Int = Self.currentSchemaVersion,
    accountServerIdentityHash: String?,
    accountIdentityHash: String? = nil,
    serverIdentityHash: String? = nil,
    continueListening: [CompanionCatalogueItem] = [],
    recentBooks: [CompanionCatalogueItem] = [],
    recentEpisodes: [CompanionCatalogueItem] = [],
    downloads: [CompanionCatalogueItem] = []
  ) {
    self.schemaVersion = schemaVersion
    self.accountServerIdentityHash = accountServerIdentityHash
    self.accountIdentityHash = accountIdentityHash ?? accountServerIdentityHash
    self.serverIdentityHash = serverIdentityHash ?? accountServerIdentityHash
    self.continueListening = continueListening
    self.recentBooks = recentBooks
    self.recentEpisodes = recentEpisodes
    self.downloads = downloads
  }

  public var isSignedIn: Bool { accountServerIdentityHash != nil }

  public func items(in section: CompanionCatalogueSection) -> [CompanionCatalogueItem] {
    switch section {
    case .continueListening: continueListening
    case .recentBooks: recentBooks
    case .recentEpisodes: recentEpisodes
    case .downloads: downloads
    }
  }
}

/// Plain persisted values consumed by `CompanionCatalogueBuilder`. Callers can gather these from
/// existing AppEnvironment readers; the builder itself never subscribes to a screen or database.
public struct CompanionCatalogueInput: Sendable {
  public let accountIdentity: AccountIdentity?
  public let continueListening: [HomeItem]
  public let currentBookmark: PlaybackBookmark?
  public let recentBooks: [HomeItem]
  public let recentEpisodes: [HomePodcastEpisode]
  public let downloads: [HomeItem]
  public let nativeDownloads: [RSSDownloadedFeed]

  public init(
    accountIdentity: AccountIdentity?,
    continueListening: [HomeItem] = [],
    currentBookmark: PlaybackBookmark? = nil,
    recentBooks: [HomeItem] = [],
    recentEpisodes: [HomePodcastEpisode] = [],
    downloads: [HomeItem] = [],
    nativeDownloads: [RSSDownloadedFeed] = []
  ) {
    self.accountIdentity = accountIdentity
    self.continueListening = continueListening
    self.currentBookmark = currentBookmark
    self.recentBooks = recentBooks
    self.recentEpisodes = recentEpisodes
    self.downloads = downloads
    self.nativeDownloads = nativeDownloads
  }
}

/// Deterministic, bounded mapper from persisted Home/podcast projections to the Watch catalogue.
/// It accepts merged shelves so publication can be wired independently of this pure foundation.
public enum CompanionCatalogueBuilder: Sendable {
  public static let maxItemsPerSection = 20
  public static let maxTitleCharacters = 120
  public static let maxSubtitleCharacters = 160

  public static func build(_ input: CompanionCatalogueInput) -> CompanionCatalogueSnapshot {
    guard let identity = input.accountIdentity else {
      return CompanionCatalogueSnapshot(accountServerIdentityHash: nil)
    }

    let identityHashes = Self.identityHashes(for: identity)
    let identityHash = identityHashes.combined
    let continueCandidates = input.continueListening.compactMap {
      Self.item(from: $0, current: false)
    }
    let bookmarkCandidate = input.currentBookmark.flatMap {
      Self.item(from: $0)
    }
    let continueListening = Self.finish(
      candidates: (bookmarkCandidate.map { [$0] } ?? []) + continueCandidates,
      limit: Self.maxItemsPerSection)

    let recentBooks = Self.finish(
      candidates: input.recentBooks.compactMap { item in
        guard item.category == .audiobook,
          let source = PodcastSourceIdentity(itemId: item.serverItemId),
          case .abs = source.source
        else { return nil }
        return Self.item(from: item, current: false)
      },
      limit: Self.maxItemsPerSection)
    let recentEpisodes = Self.finish(
      candidates: input.recentEpisodes.compactMap { Self.item(from: $0) },
      limit: Self.maxItemsPerSection)

    let absDownloads = input.downloads.compactMap { item -> Candidate? in
      guard item.isDownloaded || item.audioDownloaded else { return nil }
      return Self.item(from: item, current: false)
    }
    let nativeDownloads = input.nativeDownloads.flatMap { feed in
      feed.episodes.compactMap { episode -> Candidate? in
        guard episode.state == .completed,
          let source = PodcastSourceIdentity.rss(feedId: feed.id),
          let title = Self.text(episode.title, max: Self.maxTitleCharacters),
          let episodeID = Self.identifier(episode.id)
        else { return nil }
        let subtitle = Self.text(feed.title, max: Self.maxSubtitleCharacters)
        return Candidate(
          item: CompanionCatalogueItem(
            id: CompanionSelection(source: source, episodeID: episodeID),
            title: title,
            subtitle: subtitle,
            progressSeconds: 0,
            durationSeconds: nil,
            capabilities: CompanionCatalogueCapabilities(
              phonePlayable: true,
              watchPlayable: false,
              phoneDownloaded: true,
              watchDownloaded: false)),
          sortDate: nil,
          stableTitle: title)
      }
    }
    let downloads = Self.finish(
      candidates: absDownloads + nativeDownloads,
      limit: Self.maxItemsPerSection)

    return CompanionCatalogueSnapshot(
      accountServerIdentityHash: identityHash,
      accountIdentityHash: identityHashes.account,
      serverIdentityHash: identityHashes.server,
      continueListening: continueListening,
      recentBooks: recentBooks,
      recentEpisodes: recentEpisodes,
      downloads: downloads)
  }

  /// Stable source-qualified row identity shared by every publisher and wire mapper. Section is
  /// included so a row appearing in two shelves remains independently addressable.
  public static func rowIdentifier(
    selection: CompanionSelection, section: CompanionCatalogueSection
  ) -> String {
    let material = "\(section.rawValue)\u{1F}\(selection.source.itemId)\u{1F}\(selection.episodeID ?? "")"
    return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private struct Candidate: Sendable {
    let item: CompanionCatalogueItem
    let sortDate: Date?
    let stableTitle: String
  }

  private static func item(from home: HomeItem, current: Bool) -> Candidate? {
    // Watch playback is audio-only in this phase; a readable EPUB is not a playable catalogue
    // selection and must not be advertised as one accidentally.
    guard home.category != .ebook else { return nil }
    guard let source = PodcastSourceIdentity(itemId: home.serverItemId) else { return nil }
    let episodeID = home.episodeID.flatMap(Self.identifier)
    guard home.episodeID == nil || episodeID != nil else { return nil }
    if case .rss = source.source, episodeID == nil { return nil }
    let titleValue = home.episodeTitle ?? home.title
    guard let title = Self.text(titleValue, max: Self.maxTitleCharacters) else { return nil }
    let subtitleValue: String?
    if home.episodeID != nil {
      subtitleValue = Self.text(home.title, max: Self.maxSubtitleCharacters)
    } else {
      subtitleValue = Self.text(home.author, max: Self.maxSubtitleCharacters)
    }
    let downloaded = home.isDownloaded || home.audioDownloaded
    return Candidate(
      item: CompanionCatalogueItem(
        id: CompanionSelection(source: source, episodeID: episodeID),
        title: title,
        subtitle: subtitleValue,
        progressSeconds: Self.safeProgress(home.progressSeconds, duration: home.durationSeconds),
        durationSeconds: Self.safeDuration(home.durationSeconds),
        capabilities: CompanionCatalogueCapabilities(
          phonePlayable: true,
          watchPlayable: Self.watchPlayable(source),
          phoneDownloaded: downloaded,
          watchDownloaded: false),
        isCurrentPlayback: current,
        serverUpdatedAt: home.serverUpdatedAt),
      sortDate: home.progressRecency ?? home.addedAt,
      stableTitle: title)
  }

  private static func item(from bookmark: PlaybackBookmark) -> Candidate? {
    guard let source = PodcastSourceIdentity(itemId: bookmark.serverItemId) else { return nil }
    let episodeID = bookmark.episodeID.flatMap(Self.identifier)
    guard bookmark.episodeID == nil || episodeID != nil else { return nil }
    let titleValue = bookmark.episodeTitle ?? bookmark.title
    guard let title = Self.text(titleValue, max: Self.maxTitleCharacters) else { return nil }
    let subtitleValue = bookmark.episodeID != nil ? bookmark.showTitle : bookmark.author
    return Candidate(
      item: CompanionCatalogueItem(
        id: CompanionSelection(source: source, episodeID: episodeID),
        title: title,
        subtitle: Self.text(subtitleValue, max: Self.maxSubtitleCharacters),
        progressSeconds: Self.safeProgress(bookmark.positionSeconds, duration: bookmark.durationSeconds),
        durationSeconds: Self.safeDuration(bookmark.durationSeconds),
        capabilities: CompanionCatalogueCapabilities(
          phonePlayable: true,
          watchPlayable: Self.watchPlayable(source),
          phoneDownloaded: false,
          watchDownloaded: false),
        isCurrentPlayback: true),
      sortDate: nil,
      stableTitle: title)
  }

  private static func item(from episode: HomePodcastEpisode) -> Candidate? {
    guard let source = PodcastSourceIdentity(itemId: episode.itemID),
      let episodeID = Self.identifier(episode.episodeID),
      let title = Self.text(episode.title, max: Self.maxTitleCharacters)
    else { return nil }
    return Candidate(
      item: CompanionCatalogueItem(
        id: CompanionSelection(source: source, episodeID: episodeID),
        title: title,
        subtitle: Self.text(episode.subtitle ?? episode.showTitle, max: Self.maxSubtitleCharacters),
        progressSeconds: Self.safeProgress(episode.progressSeconds, duration: episode.durationSeconds),
        durationSeconds: Self.safeDuration(episode.durationSeconds),
        capabilities: CompanionCatalogueCapabilities(
          phonePlayable: true,
          watchPlayable: Self.watchPlayable(source),
          phoneDownloaded: false,
          watchDownloaded: false),
        serverUpdatedAt: episode.showServerUpdatedAt),
      sortDate: episode.publishedAt,
      stableTitle: title)
  }

  /// The Watch plays Audiobookshelf items from the server under its own account, so any row the
  /// phone can name from the server is a Watch candidate; the Watch still checks its account before
  /// offering playback. Native feeds live only on the phone.
  private static func watchPlayable(_ source: PodcastSourceIdentity) -> Bool {
    if case .abs = source.source { return true }
    return false
  }

  private static func finish(candidates: [Candidate], limit: Int) -> [CompanionCatalogueItem] {
    var unique: [CompanionSelection: Candidate] = [:]
    for candidate in candidates {
      let key = candidate.item.id
      guard let existing = unique[key] else {
        unique[key] = candidate
        continue
      }
      if Self.precedes(candidate, existing) { unique[key] = candidate }
    }

    return Array(
      unique.values
        .sorted { Self.precedes($0, $1) }
        .prefix(max(0, limit))
        .map(\.item))
  }

  private static func precedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
    if lhs.item.isCurrentPlayback != rhs.item.isCurrentPlayback {
      return lhs.item.isCurrentPlayback
    }
    switch (lhs.sortDate, rhs.sortDate) {
    case (let left?, let right?) where left != right:
      return left > right
    case (_?, nil):
      return true
    case (nil, _?):
      return false
    default:
      break
    }
    if lhs.item.progressSeconds != rhs.item.progressSeconds {
      return lhs.item.progressSeconds > rhs.item.progressSeconds
    }
    if lhs.stableTitle != rhs.stableTitle {
      return lhs.stableTitle.localizedStandardCompare(rhs.stableTitle) == .orderedAscending
    }
    let leftSource = lhs.item.id.source.itemId
    let rightSource = rhs.item.id.source.itemId
    if leftSource != rightSource { return leftSource < rightSource }
    return (lhs.item.id.episodeID ?? "") < (rhs.item.id.episodeID ?? "")
  }

  public static func identityHashes(for identity: AccountIdentity) -> (
    account: String, server: String, combined: String
  ) {
    let accountMaterial = "\(identity.id)\u{1F}\(identity.clientUUID)"
    let serverMaterial = identity.serverIdentityFingerprint
    let combinedMaterial = "\(accountMaterial)\u{1F}\(serverMaterial)"
    return (
      hexDigest(accountMaterial),
      hexDigest(serverMaterial),
      hexDigest(combinedMaterial)
    )
  }

  private static func hexDigest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func identifier(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false,
      trimmed.contains("://") == false,
      trimmed.lowercased().hasPrefix("file:") == false,
      trimmed.contains("\n") == false,
      trimmed.contains("\r") == false
    else { return nil }
    return trimmed
  }

  private static func text(_ value: String?, max: Int) -> String? {
    guard let value, let identifier = Self.identifier(value) else { return nil }
    // `DefaultRSSDownloadsReading` retains a feed URL as a fallback display title when a feed has
    // no title. That transport value must never become Watch metadata, even through a presentation
    // fallback. The same guard protects malformed persisted titles and local file paths.
    guard identifier.contains("://") == false,
      identifier.hasPrefix("www.") == false,
      identifier.hasPrefix("file:") == false,
      identifier.hasPrefix("/") == false,
      identifier.contains("\n") == false,
      identifier.contains("\r") == false
    else { return nil }
    var bounded = String(identifier.prefix(max))
    while bounded.utf8.count > WatchProtocolMetadataLimit.bytes {
      bounded.removeLast()
    }
    return bounded.isEmpty ? nil : bounded
  }

  private enum WatchProtocolMetadataLimit {
    static let bytes = 512
  }

  private static func safeNonNegative(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return max(0, value)
  }

  /// The wire validator rejects progress past duration, which would drop the whole row.
  private static func safeProgress(_ value: Double, duration: Double?) -> Double {
    let progress = safeNonNegative(value)
    guard let duration = safeDuration(duration) else { return progress }
    return min(progress, duration)
  }

  private static func safeDuration(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value > 0 else { return nil }
    return value
  }
}

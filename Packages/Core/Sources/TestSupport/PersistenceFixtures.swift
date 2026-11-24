import Foundation
import GRDB
import Persistence

/// Rows the persistence suites insert most often.
///
/// Every parameter is explicit and mirrored into the record, so a suite that relied on a literal
/// row reproduces the same stored values. Pass a field to override the shared default rather than
/// writing another local builder.
public enum PersistenceFixtures {
  public static func account(
    clientUUID: String = UUID().uuidString,
    serverBaseURL: String = "https://example.com",
    serverUserId: String = "user-1",
    serverVersion: String = "2.10.0",
    defaultLibraryId: String? = nil,
    librarySelectionMode: LibrarySelectionMode = .all,
    signsInWithOpenID: Bool = false
  ) -> AccountRecord {
    AccountRecord(
      clientUUID: clientUUID,
      serverBaseURL: serverBaseURL,
      serverUserId: serverUserId,
      serverVersion: serverVersion,
      defaultLibraryId: defaultLibraryId,
      librarySelectionMode: librarySelectionMode,
      signsInWithOpenID: signsInWithOpenID)
  }

  public static func item(
    accountId: Int64,
    libraryId: Int64,
    serverItemId: String = "item-1",
    mediaKind: String = "book",
    title: String = "Title",
    sortTitle: String = "title",
    author: String? = nil,
    durationSeconds: Double? = nil,
    itemDescription: String? = nil,
    addedAt: Date? = nil,
    numAudioFiles: Int? = nil,
    ebookFormat: String? = nil,
    ebookFileIno: String? = nil,
    ebookFileExt: String? = nil,
    seriesName: String? = nil,
    narratorName: String? = nil,
    expandedMetadataFetchedAt: Date? = nil,
    serverUpdatedAt: Date? = nil,
    podcastServerEpisodeCount: Int? = nil,
    podcastFeedFingerprint: String? = nil,
    podcastLanguage: String? = nil,
    hasServerArtwork: Bool? = nil,
    softDeleted: Bool = false
  ) -> ItemRecord {
    ItemRecord(
      accountId: accountId,
      libraryId: libraryId,
      serverItemId: serverItemId,
      mediaKind: mediaKind,
      title: title,
      sortTitle: sortTitle,
      author: author,
      durationSeconds: durationSeconds,
      itemDescription: itemDescription,
      addedAt: addedAt,
      numAudioFiles: numAudioFiles,
      ebookFormat: ebookFormat,
      ebookFileIno: ebookFileIno,
      ebookFileExt: ebookFileExt,
      seriesName: seriesName,
      narratorName: narratorName,
      expandedMetadataFetchedAt: expandedMetadataFetchedAt,
      serverUpdatedAt: serverUpdatedAt,
      podcastServerEpisodeCount: podcastServerEpisodeCount,
      podcastFeedFingerprint: podcastFeedFingerprint,
      podcastLanguage: podcastLanguage,
      hasServerArtwork: hasServerArtwork,
      softDeleted: softDeleted)
  }

  public static func episode(
    accountId: Int64,
    itemId: Int64,
    serverEpisodeId: String = "ep-1",
    title: String = "Episode",
    subtitle: String? = nil,
    episodeDescription: String? = nil,
    seasonNumber: String? = nil,
    episodeNumber: String? = nil,
    episodeType: String? = nil,
    durationSeconds: Double? = nil,
    sizeBytes: Int? = nil,
    publishedAt: Date? = nil,
    storedAudioIno: String? = nil,
    storedAudioExpectedSize: Int? = nil,
    storedAudioMimeType: String? = nil,
    storedAudioDurationSeconds: Double? = nil,
    lastSeenGeneration: Int = 1,
    softDeleted: Bool = false
  ) -> PodcastEpisodeRecord {
    PodcastEpisodeRecord(
      accountId: accountId,
      itemId: itemId,
      serverEpisodeId: serverEpisodeId,
      title: title,
      subtitle: subtitle,
      episodeDescription: episodeDescription,
      seasonNumber: seasonNumber,
      episodeNumber: episodeNumber,
      episodeType: episodeType,
      durationSeconds: durationSeconds,
      sizeBytes: sizeBytes,
      publishedAt: publishedAt,
      storedAudioIno: storedAudioIno,
      storedAudioExpectedSize: storedAudioExpectedSize,
      storedAudioMimeType: storedAudioMimeType,
      storedAudioDurationSeconds: storedAudioDurationSeconds,
      lastSeenGeneration: lastSeenGeneration,
      softDeleted: softDeleted)
  }

  // MARK: - Inserting

  @discardableResult
  public static func insertAccount(
    _ database: AppDatabase,
    clientUUID: String = UUID().uuidString,
    serverBaseURL: String = "https://example.com",
    serverUserId: String = "user-1",
    serverVersion: String = "2.10.0",
    defaultLibraryId: String? = nil,
    librarySelectionMode: LibrarySelectionMode = .all,
    signsInWithOpenID: Bool = false
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      try insertAccount(
        in: db, clientUUID: clientUUID, serverBaseURL: serverBaseURL,
        serverUserId: serverUserId, serverVersion: serverVersion,
        defaultLibraryId: defaultLibraryId, librarySelectionMode: librarySelectionMode,
        signsInWithOpenID: signsInWithOpenID)
    }
  }

  @discardableResult
  public static func insertAccount(
    in db: Database,
    clientUUID: String = UUID().uuidString,
    serverBaseURL: String = "https://example.com",
    serverUserId: String = "user-1",
    serverVersion: String = "2.10.0",
    defaultLibraryId: String? = nil,
    librarySelectionMode: LibrarySelectionMode = .all,
    signsInWithOpenID: Bool = false
  ) throws -> Int64 {
    var account = account(
      clientUUID: clientUUID, serverBaseURL: serverBaseURL, serverUserId: serverUserId,
      serverVersion: serverVersion, defaultLibraryId: defaultLibraryId,
      librarySelectionMode: librarySelectionMode, signsInWithOpenID: signsInWithOpenID)
    try account.insert(db)
    return account.id!
  }

  @discardableResult
  public static func insertItem(
    _ database: AppDatabase,
    accountId: Int64,
    libraryId: Int64,
    serverItemId: String = "item-1",
    mediaKind: String = "book",
    title: String = "Title",
    sortTitle: String = "title",
    author: String? = nil,
    durationSeconds: Double? = nil,
    itemDescription: String? = nil,
    addedAt: Date? = nil,
    numAudioFiles: Int? = nil,
    ebookFormat: String? = nil,
    ebookFileIno: String? = nil,
    ebookFileExt: String? = nil,
    seriesName: String? = nil,
    narratorName: String? = nil,
    expandedMetadataFetchedAt: Date? = nil,
    serverUpdatedAt: Date? = nil,
    podcastServerEpisodeCount: Int? = nil,
    podcastFeedFingerprint: String? = nil,
    podcastLanguage: String? = nil,
    hasServerArtwork: Bool? = nil,
    softDeleted: Bool = false
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      try insertItem(
        in: db, accountId: accountId, libraryId: libraryId, serverItemId: serverItemId,
        mediaKind: mediaKind, title: title, sortTitle: sortTitle, author: author,
        durationSeconds: durationSeconds, itemDescription: itemDescription, addedAt: addedAt,
        numAudioFiles: numAudioFiles, ebookFormat: ebookFormat, ebookFileIno: ebookFileIno,
        ebookFileExt: ebookFileExt, seriesName: seriesName, narratorName: narratorName,
        expandedMetadataFetchedAt: expandedMetadataFetchedAt, serverUpdatedAt: serverUpdatedAt,
        podcastServerEpisodeCount: podcastServerEpisodeCount,
        podcastFeedFingerprint: podcastFeedFingerprint, podcastLanguage: podcastLanguage,
        hasServerArtwork: hasServerArtwork, softDeleted: softDeleted)
    }
  }

  @discardableResult
  public static func insertItem(
    in db: Database,
    accountId: Int64,
    libraryId: Int64,
    serverItemId: String = "item-1",
    mediaKind: String = "book",
    title: String = "Title",
    sortTitle: String = "title",
    author: String? = nil,
    durationSeconds: Double? = nil,
    itemDescription: String? = nil,
    addedAt: Date? = nil,
    numAudioFiles: Int? = nil,
    ebookFormat: String? = nil,
    ebookFileIno: String? = nil,
    ebookFileExt: String? = nil,
    seriesName: String? = nil,
    narratorName: String? = nil,
    expandedMetadataFetchedAt: Date? = nil,
    serverUpdatedAt: Date? = nil,
    podcastServerEpisodeCount: Int? = nil,
    podcastFeedFingerprint: String? = nil,
    podcastLanguage: String? = nil,
    hasServerArtwork: Bool? = nil,
    softDeleted: Bool = false
  ) throws -> Int64 {
    var item = item(
      accountId: accountId, libraryId: libraryId, serverItemId: serverItemId,
      mediaKind: mediaKind, title: title, sortTitle: sortTitle, author: author,
      durationSeconds: durationSeconds, itemDescription: itemDescription, addedAt: addedAt,
      numAudioFiles: numAudioFiles, ebookFormat: ebookFormat, ebookFileIno: ebookFileIno,
      ebookFileExt: ebookFileExt, seriesName: seriesName, narratorName: narratorName,
      expandedMetadataFetchedAt: expandedMetadataFetchedAt, serverUpdatedAt: serverUpdatedAt,
      podcastServerEpisodeCount: podcastServerEpisodeCount,
      podcastFeedFingerprint: podcastFeedFingerprint, podcastLanguage: podcastLanguage,
      hasServerArtwork: hasServerArtwork, softDeleted: softDeleted)
    try item.insert(db)
    return item.id!
  }

  @discardableResult
  public static func insertEpisode(
    _ database: AppDatabase,
    accountId: Int64,
    itemId: Int64,
    serverEpisodeId: String = "ep-1",
    title: String = "Episode",
    durationSeconds: Double? = nil,
    publishedAt: Date? = nil,
    lastSeenGeneration: Int = 1,
    softDeleted: Bool = false
  ) async throws -> Int64 {
    try await database.writeAsync { db in
      try insertEpisode(
        in: db, accountId: accountId, itemId: itemId, serverEpisodeId: serverEpisodeId,
        title: title, durationSeconds: durationSeconds, publishedAt: publishedAt,
        lastSeenGeneration: lastSeenGeneration, softDeleted: softDeleted)
    }
  }

  @discardableResult
  public static func insertEpisode(
    in db: Database,
    accountId: Int64,
    itemId: Int64,
    serverEpisodeId: String = "ep-1",
    title: String = "Episode",
    durationSeconds: Double? = nil,
    publishedAt: Date? = nil,
    lastSeenGeneration: Int = 1,
    softDeleted: Bool = false
  ) throws -> Int64 {
    var episode = episode(
      accountId: accountId, itemId: itemId, serverEpisodeId: serverEpisodeId, title: title,
      durationSeconds: durationSeconds, publishedAt: publishedAt,
      lastSeenGeneration: lastSeenGeneration, softDeleted: softDeleted)
    try episode.insert(db)
    return episode.id!
  }
}

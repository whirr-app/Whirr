import ABSApi
import AppModel
import CryptoKit
import Foundation
import Persistence
import WidgetProtocol

/// A cover the publisher should export so that a later snapshot can name it.
nonisolated struct WidgetCoverRequest: Sendable, Equatable {
  let fileName: String
  let key: ArtworkKey
}

/// One publication's three outputs: the file the extension draws, the app-private map its tokens
/// resolve through, and the covers it would draw if they were on disk.
nonisolated struct WidgetPublication: Sendable, Equatable {
  let snapshot: WidgetSnapshot
  let selections: [String: CompanionSelection]
  let coverRequests: [WidgetCoverRequest]
}

/// Builds a publication from the persisted shelves and the player's state. Pure, so the widget
/// rules are testable without a database, player or file system. Rows come from `HomeItem` and
/// `HomePodcastEpisode`, not `CompanionCatalogueBuilder`, which drops the cover source, carries no
/// kind, and lets a bookmark's row replace the real Continue Listening row.
nonisolated struct WidgetSnapshotAssembly: Sendable {
  var accountStamp: WidgetAccountStamp
  /// Per binding. Tokens and cover names are digests of it, so they are stable while a binding
  /// lasts (identical content writes identical files) and mean nothing outside it.
  var tokenSalt: String
  var nativeEnabled: Bool
  var absContinue: [HomeItem]
  var nativeContinue: [HomeItem]
  var absLatest: HomeLatestPodcastEpisodesSnapshot?
  var nativeLatest: [HomePodcastEpisode]
  var bookmark: PlaybackBookmark?
  /// What the player has loaded, when anything is.
  var loaded: CompanionSelection?
  var isPlaying: Bool
  var skipBackSeconds: Int
  var generatedAt: Date
  /// The account's Audiobookshelf cover source; `nil` leaves ABS rows without a cover.
  var absArtworkSource: ArtworkSource?
  var coverPixelWidth: Int
  /// Cover files already exported. A row names its cover only when the file exists, so the
  /// extension never draws a missing image.
  var exportedCovers: Set<String>
  /// The listening-stats window, already assembled from the stored snapshot; `nil` until one exists.
  var stats: WidgetStats? = nil

  /// One drawn row before it is given a token; shared with `WidgetSmartListAssembly`.
  struct Row {
    let selection: CompanionSelection
    let kind: WidgetItemKind
    let title: String
    let subtitle: String?
    let progressSeconds: Double
    let durationSeconds: Double?
    let isDownloaded: Bool
    let cover: ArtworkKey?
  }

  func makePublication() -> WidgetPublication? {
    let limit = WidgetSnapshotLimits.maxItemsPerShelf
    let current = currentSelection
    var continueRows = ContinueListeningMerge.merge(
      abs: absContinue, rss: nativeContinue, nativeSubscriptionsEnabled: nativeEnabled, limit: limit
    ).compactMap(row(continuing:))
    // The bookmark's title leads the shelf when the shelf does not already hold it (a title just
    // started has no progress row yet). When the shelf does hold it, that row stays as it is, so
    // it keeps its cover revision and download state.
    if let current, !continueRows.contains(where: { $0.selection == current }),
      let bookmarkRow = row(bookmark: bookmark, matching: current)
    {
      continueRows = Array(([bookmarkRow] + continueRows).prefix(limit))
    }
    let latestRows = LatestPodcastEpisodesMerge.merge(
      snapshot: absLatest ?? HomeLatestPodcastEpisodesSnapshot(all: [], nativePreferred: []),
      rss: nativeLatest, nativeSubscriptionsEnabled: nativeEnabled, limit: limit
    ).compactMap(row(episode:))

    var selections: [String: CompanionSelection] = [:]
    var coverRequests: [WidgetCoverRequest] = []
    func items(_ rows: [Row]) -> [WidgetItem] {
      rows.compactMap { row in
        let token = Self.token(for: row.selection, salt: tokenSalt)
        var coverFileName: String?
        if let key = row.cover {
          let fileName = Self.coverFileName(for: key, salt: tokenSalt)
          if !coverRequests.contains(where: { $0.fileName == fileName }) {
            coverRequests.append(WidgetCoverRequest(fileName: fileName, key: key))
          }
          if exportedCovers.contains(fileName) { coverFileName = fileName }
        }
        guard let item = Self.item(row, token: token, coverFileName: coverFileName) else { return nil }
        selections[token] = row.selection
        return item
      }
    }
    let continueItems = items(continueRows)
    let latestItems = items(latestRows)
    let nowPlaying = current.flatMap { selection -> WidgetNowPlaying? in
      let token = Self.token(for: selection, salt: tokenSalt)
      return try? WidgetNowPlaying(token: selections[token] == nil ? nil : token, isPlaying: isPlaying)
    }
    guard
      let snapshot = try? WidgetSnapshot(
        generatedAt: generatedAt, accountStamp: accountStamp, nowPlaying: nowPlaying,
        skipBackSeconds: skipBackSeconds, continueListening: continueItems,
        latestEpisodes: latestItems, stats: stats)
    else { return nil }
    return WidgetPublication(snapshot: snapshot, selections: selections, coverRequests: coverRequests)
  }

  /// The loaded item, else the bookmark's: what the play control resumes.
  private var currentSelection: CompanionSelection? {
    if let loaded { return allowed(loaded) ? loaded : nil }
    guard let bookmark, let source = PodcastSourceIdentity(itemId: bookmark.serverItemId) else { return nil }
    let selection = CompanionSelection(source: source, episodeID: bookmark.episodeID)
    return allowed(selection) ? selection : nil
  }

  /// RSS rows exist only while native subscriptions are enabled, as on Home.
  private func allowed(_ selection: CompanionSelection) -> Bool {
    if case .rss = selection.source.source { return nativeEnabled }
    return true
  }

  private func row(continuing item: HomeItem) -> Row? {
    guard let source = PodcastSourceIdentity(itemId: item.serverItemId) else { return nil }
    let selection = CompanionSelection(source: source, episodeID: item.episodeID)
    let isEpisode = item.episodeID != nil
    return Row(
      selection: selection, kind: Self.kind(of: selection),
      title: (isEpisode ? item.episodeTitle : nil) ?? item.title,
      subtitle: isEpisode ? item.title : item.author,
      progressSeconds: item.progressSeconds, durationSeconds: item.durationSeconds,
      isDownloaded: item.isDownloaded,
      cover: coverKey(
        itemID: item.serverItemId, providerSource: item.itemSummary.providerArtworkSource,
        revision: item.artworkRevision))
  }

  private func row(bookmark: PlaybackBookmark?, matching selection: CompanionSelection) -> Row? {
    guard let bookmark, !bookmark.isFinished, bookmark.serverItemId == selection.itemID,
      bookmark.episodeID == selection.episodeID
    else { return nil }
    let isEpisode = bookmark.episodeID != nil
    return Row(
      selection: selection, kind: Self.kind(of: selection),
      title: (isEpisode ? bookmark.episodeTitle : nil) ?? bookmark.title,
      subtitle: isEpisode ? (bookmark.showTitle ?? bookmark.title) : bookmark.author,
      progressSeconds: bookmark.positionSeconds, durationSeconds: bookmark.durationSeconds,
      isDownloaded: false,
      // The bookmark carries no cover revision or feed artwork: an ABS cover is drawn
      // unversioned, and an RSS one not at all, until the title reaches the shelf.
      cover: coverKey(itemID: bookmark.serverItemId, providerSource: nil, revision: .unversioned))
  }

  private func row(episode: HomePodcastEpisode) -> Row? {
    Self.row(
      episode: episode, isDownloaded: false, absArtworkSource: absArtworkSource,
      coverPixelWidth: coverPixelWidth)
  }

  static func row(
    episode: HomePodcastEpisode, isDownloaded: Bool, absArtworkSource: ArtworkSource?,
    coverPixelWidth: Int
  ) -> Row? {
    guard let source = PodcastSourceIdentity(itemId: episode.itemID) else { return nil }
    let selection = CompanionSelection(source: source, episodeID: episode.episodeID)
    return Row(
      selection: selection, kind: kind(of: selection), title: episode.title,
      subtitle: episode.showTitle, progressSeconds: episode.progressSeconds,
      durationSeconds: episode.durationSeconds, isDownloaded: isDownloaded,
      cover: coverKey(
        itemID: episode.itemID, providerSource: episode.providerArtworkSource,
        revision: episode.artworkRevision, absArtworkSource: absArtworkSource,
        pixelWidth: coverPixelWidth))
  }

  private func coverKey(itemID: String, providerSource: ArtworkSource?, revision: ArtworkRevision)
    -> ArtworkKey?
  {
    Self.coverKey(
      itemID: itemID, providerSource: providerSource, revision: revision,
      absArtworkSource: absArtworkSource, pixelWidth: coverPixelWidth)
  }

  /// A device-owned feed draws its own artwork; everything else draws the account's ABS cover.
  /// An RSS title with no declared artwork has no cover rather than a server one it lacks.
  private static func coverKey(
    itemID: String, providerSource: ArtworkSource?, revision: ArtworkRevision,
    absArtworkSource: ArtworkSource?, pixelWidth coverPixelWidth: Int
  ) -> ArtworkKey? {
    let source: ArtworkSource
    if let providerSource {
      source = providerSource
    } else if PodcastSourceIdentity(itemId: itemID)?.rssFeedId == nil, let absArtworkSource {
      source = absArtworkSource
    } else {
      return nil
    }
    return ArtworkKey(
      source: source, itemID: itemID, variant: .homeCard(pixelWidth: coverPixelWidth),
      revision: revision)
  }

  static func kind(of selection: CompanionSelection) -> WidgetItemKind {
    if case .rss = selection.source.source { return .feedEpisode }
    return selection.episodeID == nil ? .book : .serverEpisode
  }

  static func item(_ row: Row, token: String, coverFileName: String?) -> WidgetItem? {
    guard let title = drawableText(row.title) else { return nil }
    let duration = row.durationSeconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    let progress = row.progressSeconds.isFinite ? max(0, row.progressSeconds) : 0
    let fraction = duration.map { min(1, progress / $0) } ?? 0
    return try? WidgetItem(
      token: token, kind: row.kind, title: title, subtitle: drawableText(row.subtitle),
      progressFraction: fraction, remainingSeconds: duration.map { max(0, $0 - progress) },
      coverFileName: coverFileName, isDownloaded: row.isDownloaded)
  }

  /// Text the snapshot will accept: control characters become spaces, the result is trimmed and
  /// cut on a character boundary to the byte limit, and anything shaped like a URL or a path is
  /// dropped rather than drawn.
  static func drawableText(_ raw: String?) -> String? {
    guard let raw else { return nil }
    var scalars = String.UnicodeScalarView()
    for scalar in raw.unicodeScalars {
      scalars.append(CharacterSet.controlCharacters.contains(scalar) ? " " : scalar)
    }
    var text = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    while text.utf8.count > WidgetSnapshotLimits.maxTextBytes { text.removeLast() }
    text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, !text.contains("://"), !text.lowercased().hasPrefix("file:"),
      !text.hasPrefix("/")
    else { return nil }
    return text
  }

  static func token(for selection: CompanionSelection, salt: String) -> String {
    digest(["token", salt, selection.itemID, selection.episodeID ?? ""])
  }

  /// The cover's name changes with its source and revision, so a replaced cover is a new file
  /// the extension has never cached.
  static func coverFileName(for key: ArtworkKey, salt: String) -> String {
    let name = digest([
      "cover", salt, key.itemID, key.accountScope.rawValue, key.revision.rawValue,
      String(key.variant.pixelWidth),
    ])
    return "\(name).\(WidgetStorageLayout.coverFileExtension)"
  }

  static func digest(_ parts: [String]) -> String {
    let material = parts.joined(separator: "\u{1F}")
    let hex = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    return String(hex.prefix(32))
  }
}

import Persistence

/// What a collection or playlist screen's selection can do. Every action runs through
/// `ItemActionsModel.performBatch`.
public enum LibraryCollectionSelectionAction: Sendable, Hashable, CaseIterable {
  case download, markAsFinished, resetProgress, addToUpNext, saveForLater, removeDownload

  public var title: String {
    switch self {
    case .download: MediaActionCopy.download.title
    case .markAsFinished: MediaActionCopy.markAsFinished.title
    case .resetProgress: MediaActionCopy.resetProgress.title
    case .addToUpNext: MediaActionCopy.addToUpNext.title
    case .saveForLater: MediaActionCopy.saveForLater.title
    case .removeDownload: MediaActionCopy.removeDownloads.title
    }
  }

  public var batchAction: ItemBatchAction {
    switch self {
    case .download: .download
    case .markAsFinished: .markAsFinished
    case .resetProgress: .resetProgress
    case .addToUpNext: .addToUpNext
    case .saveForLater: .saveForLater
    case .removeDownload: .removeDownload
    }
  }
}

/// Which selected entries each `LibraryCollectionSelectionAction` applies to, as
/// `SavedForLaterSelectionPolicy` does for Saved for Later. Every entry is selectable: the screen
/// only lists entries the local catalogue holds.
public enum LibraryCollectionSelectionPolicy {
  /// The selected entries in the list's order, whatever order `ids` came in.
  public static func selectedEntries(
    _ entries: [LibraryCollectionEntry], ids: Set<String>
  ) -> [LibraryCollectionEntry] {
    entries.filter { ids.contains($0.id) }
  }

  /// Nil for a document Whirr cannot open, and for a whole podcast show (a collection can name
  /// one; only its episodes have item actions).
  public static func capability(for entry: LibraryCollectionEntry) -> ItemMediaCapability? {
    switch entry {
    case .episode: return .podcast
    case .title(let summary, _):
      guard summary.category != .podcast else { return nil }
      let capability = ItemMediaCapability.derive(
        category: summary.category, hasReadableEbook: summary.hasReadableEbook)
      return capability == .unsupportedDocument ? nil : capability
    }
  }

  /// Whether Download must ask audio, eBook or both for this entry.
  public static func offersFormatChoice(for entry: LibraryCollectionEntry) -> Bool {
    capability(for: entry)?.offersFormatChoice ?? false
  }

  public static func downloadFormat(
    for entry: LibraryCollectionEntry, requested: ItemDownloadFormat?
  ) -> ItemDownloadFormat? {
    capability(for: entry)?.downloadFormat(requested: requested)
  }

  /// From the entry's own projection. A title's ebook-only progress is not in `ItemSummary`, so a
  /// book read but not listened to counts as untouched.
  public static func playbackStatus(for entry: LibraryCollectionEntry) -> ItemPlaybackStatus? {
    switch entry {
    case .title(let summary, let isFinished):
      MediaProgressActionPolicy.playbackStatus(
        progressSeconds: summary.progressSeconds, isFinished: isFinished)
    case .episode(let episode):
      MediaProgressActionPolicy.playbackStatus(
        progressSeconds: episode.progressSeconds, isFinished: episode.isFinished)
    }
  }

  /// `isSaved` is nil until saved membership has resolved; Save for Later is withheld until then.
  public static func accepts(
    _ action: LibraryCollectionSelectionAction, entry: LibraryCollectionEntry,
    deviceAction: ItemContextMenuDownloadAction, isSaved: Bool?, nowPlaying: ListeningIdentity?
  ) -> Bool {
    guard let capability = capability(for: entry) else { return false }
    switch action {
    case .download: return capability.supportsDownload && deviceAction == .download
    case .removeDownload: return capability.supportsDownload && deviceAction == .remove
    case .markAsFinished:
      return MediaProgressActionPolicy.actions(for: playbackStatus(for: entry)).contains(.markAsFinished)
    case .resetProgress:
      return MediaProgressActionPolicy.actions(for: playbackStatus(for: entry)).contains(.resetProgress)
    case .addToUpNext:
      return ListeningQueueActionPolicy.availability(
        itemID: entry.itemID, episodeID: entry.episodeID, category: entry.category,
        nowPlaying: nowPlaying
      ).offersAddToUpNext
    case .saveForLater: return isSaved == false
    }
  }

  public static func batchTarget(
    for entry: LibraryCollectionEntry, downloadFormat: ItemDownloadFormat?
  ) -> ItemBatchTarget {
    ItemBatchTarget(
      itemID: entry.itemID, episodeID: entry.episodeID, category: entry.category,
      durationSeconds: entry.durationSeconds, downloadFormat: downloadFormat)
  }
}

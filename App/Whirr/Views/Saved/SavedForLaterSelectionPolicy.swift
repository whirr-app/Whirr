import AppModel
import Persistence

enum SavedForLaterSelectionAction: Hashable {
  case removeFromSaved, download, removeDownload, markAsFinished, resetProgress, addToUpNext

  var title: String {
    switch self {
    case .removeFromSaved: MediaActionCopy.removeFromSaved.title
    case .download: MediaActionCopy.download.title
    case .removeDownload: MediaActionCopy.removeDownloads.title
    case .markAsFinished: MediaActionCopy.markAsFinished.title
    case .resetProgress: MediaActionCopy.resetProgress.title
    case .addToUpNext: MediaActionCopy.addToUpNext.title
    }
  }

  var batchAction: ItemBatchAction {
    switch self {
    case .removeFromSaved: .removeFromSaved
    case .download: .download
    case .removeDownload: .removeDownload
    case .markAsFinished: .markAsFinished
    case .resetProgress: .resetProgress
    case .addToUpNext: .addToUpNext
    }
  }
}

enum SavedForLaterSelectionPolicy {
  static func selectedEntries(_ entries: [SavedShelfItem], ids: Set<SavedShelfIdentity>) -> [SavedShelfItem] {
    entries.filter { ids.contains($0.identity) }
  }

  static func capability(for entry: SavedShelfItem) -> ItemMediaCapability? {
    guard !entry.isUnavailable else { return nil }
    if entry.episode != nil { return .podcast }
    guard let summary = entry.itemSummary, entry.category != .podcast else { return nil }
    let capability = ItemMediaCapability.derive(category: entry.category, hasReadableEbook: summary.hasReadableEbook)
    return capability == .unsupportedDocument ? nil : capability
  }

  static func downloadFormat(for entry: SavedShelfItem, requested: ItemDownloadFormat?) -> ItemDownloadFormat? {
    capability(for: entry)?.downloadFormat(requested: requested)
  }

  static func accepts(
    _ action: SavedForLaterSelectionAction, entry: SavedShelfItem,
    deviceAction: ItemContextMenuDownloadAction, nowPlaying: ListeningIdentity?,
    itemPlaybackStatus: ItemPlaybackStatus?
  ) -> Bool {
    if action == .removeFromSaved { return true }
    guard let capability = capability(for: entry) else { return false }
    switch action {
    case .download: return capability.supportsDownload && deviceAction == .download
    case .removeDownload: return capability.supportsDownload && deviceAction == .remove
    case .markAsFinished:
      return MediaProgressActionPolicy.actions(for: playbackStatus(entry, itemPlaybackStatus: itemPlaybackStatus))
        .contains(.markAsFinished)
    case .resetProgress:
      return MediaProgressActionPolicy.actions(for: playbackStatus(entry, itemPlaybackStatus: itemPlaybackStatus))
        .contains(.resetProgress)
    case .addToUpNext:
      let parts = entry.identity
      return ListeningQueueActionPolicy.availability(
        itemID: parts.itemID, episodeID: parts.episodeID, category: entry.category,
        nowPlaying: nowPlaying
      ).offersAddToUpNext
    case .removeFromSaved: return true
    }
  }

  static func playbackStatus(_ entry: SavedShelfItem, itemPlaybackStatus: ItemPlaybackStatus?) -> ItemPlaybackStatus? {
    if let episode = entry.episode {
      return MediaProgressActionPolicy.playbackStatus(
        progressSeconds: episode.progressSeconds, isFinished: episode.isFinished)
    }
    // ItemSummary omits ebook progress and completion; use the screen's existing durable store.
    return itemPlaybackStatus
  }
}

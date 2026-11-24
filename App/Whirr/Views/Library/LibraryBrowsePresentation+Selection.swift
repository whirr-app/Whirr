import AppModel
import Persistence

extension LibraryBrowsePresentation {
  enum SelectionAction: Hashable {
    case download, downloadAudio, downloadEbooks, downloadAllFormats
    case removeDownloads, markAsFinished, resetProgress, addToUpNext, saveForLater

    var batchAction: ItemBatchAction {
      switch self {
      case .download, .downloadAudio, .downloadEbooks, .downloadAllFormats: .download
      case .removeDownloads: .removeDownload
      case .markAsFinished: .markAsFinished
      case .resetProgress: .resetProgress
      case .addToUpNext: .addToUpNext
      case .saveForLater: .saveForLater
      }
    }

    func requiresConfirmation(affectedCount: Int) -> Bool {
      guard affectedCount > 0 else { return false }
      switch self {
      case .removeDownloads, .resetProgress: return true
      case .download, .downloadAudio, .downloadEbooks, .downloadAllFormats, .markAsFinished, .addToUpNext:
        return affectedCount >= 10
      case .saveForLater: return false
      }
    }

    func confirmationButtonTitle(affectedCount: Int) -> String {
      let titles = "\(affectedCount) \(affectedCount == 1 ? "Title" : "Titles")"
      switch self {
      case .download: return "Download \(titles)"
      case .downloadAudio: return "Download Audio for \(titles)"
      case .downloadEbooks: return "Download eBooks for \(titles)"
      case .downloadAllFormats: return "Download All Formats for \(titles)"
      case .removeDownloads: return "Remove Downloads for \(titles)"
      case .markAsFinished: return "Mark \(titles) as Finished"
      case .resetProgress: return "Reset Progress for \(titles)"
      case .addToUpNext: return "Add \(titles) to Up Next"
      case .saveForLater: return "Save \(titles) for Later"
      }
    }

    func confirmationMessage(affectedCount: Int) -> String {
      let titles = "\(affectedCount) \(affectedCount == 1 ? "title" : "titles")"
      switch self {
      case .download:
        return "This will queue \(titles) for download and use storage on this device."
      case .downloadAudio:
        return "This will queue audio for \(titles) for download and use storage on this device."
      case .downloadEbooks:
        return "This will queue eBooks for \(titles) for download and use storage on this device."
      case .downloadAllFormats:
        return "This will queue all available formats for \(titles) for download and use storage on this device."
      case .removeDownloads:
        return "This will remove downloads for \(titles) from this device."
      case .markAsFinished:
        return "This will mark \(titles) as finished and update your progress."
      case .resetProgress:
        return "This will reset progress for \(titles) to the beginning."
      case .addToUpNext:
        return "This will add \(titles) to your Up Next queue."
      case .saveForLater:
        return "This will save \(titles) for later."
      }
    }

    var title: String {
      switch self {
      case .download: MediaActionCopy.download.title
      case .downloadAudio: "Download Audio"
      case .downloadEbooks: "Download eBooks"
      case .downloadAllFormats: "Download All Available Formats"
      case .removeDownloads: MediaActionCopy.removeDownloads.title
      case .markAsFinished: MediaActionCopy.markAsFinished.title
      case .resetProgress: MediaActionCopy.resetProgress.title
      case .addToUpNext: MediaActionCopy.addToUpNext.title
      case .saveForLater: MediaActionCopy.saveForLater.title
      }
    }

    var systemImage: String {
      switch self {
      case .download, .downloadAudio, .downloadEbooks, .downloadAllFormats:
        MediaActionCopy.download.systemImage
      case .removeDownloads: MediaActionCopy.removeDownloads.systemImage
      case .markAsFinished: MediaActionCopy.markAsFinished.systemImage
      case .resetProgress: MediaActionCopy.resetProgress.systemImage
      case .addToUpNext: MediaActionCopy.addToUpNext.systemImage
      case .saveForLater: MediaActionCopy.saveForLater.systemImage
      }
    }
  }

  /// Shows have episode-level semantics; unsupported documents offer details only in their menu.
  nonisolated static func isSelectable(_ item: ItemSummary) -> Bool {
    item.category != .podcast
      && ItemMediaCapability.derive(category: item.category, hasReadableEbook: item.hasReadableEbook)
        != .unsupportedDocument
  }

  /// The quick-filtered rows a select-all would take: only media that can be selected.
  static func selectionItems(from quickFilteredItems: [ItemSummary]) -> [ItemSummary] {
    quickFilteredItems.filter(isSelectable)
  }

  static func selectedItems(_ items: [ItemSummary], ids: Set<String>) -> [ItemSummary] {
    items.filter { ids.contains($0.serverItemId) && isSelectable($0) }
  }

  static func selectionDownloadFormat(_ action: SelectionAction, item: ItemSummary) -> ItemDownloadFormat? {
    guard isSelectable(item) else { return nil }
    let formats = ItemMediaCapability.derive(
      category: item.category, hasReadableEbook: item.hasReadableEbook
    ).downloadFormats
    switch action {
    case .download: return formats.count == 1 ? formats.first : nil
    case .downloadAudio: return formats.contains(.audio) ? .audio : nil
    case .downloadEbooks: return formats.contains(.ebook) ? .ebook : nil
    case .downloadAllFormats: return formats.contains(.both) ? .both : formats.first
    default: return nil
    }
  }

  static func selectionSupports(
    _ action: SelectionAction, item: ItemSummary, deviceAction: ItemContextMenuDownloadAction,
    playbackStatus: ItemPlaybackStatus?, isSaved: Bool?, nowPlaying: ListeningIdentity?
  ) -> Bool {
    guard isSelectable(item) else { return false }
    switch action {
    case .download, .downloadAudio, .downloadEbooks, .downloadAllFormats:
      return deviceAction == .download && selectionDownloadFormat(action, item: item) != nil
    case .removeDownloads: return deviceAction == .remove
    case .markAsFinished:
      return MediaProgressActionPolicy.actions(for: playbackStatus).contains(.markAsFinished)
    case .resetProgress:
      return MediaProgressActionPolicy.actions(for: playbackStatus).contains(.resetProgress)
    case .saveForLater: return isSaved == false
    case .addToUpNext:
      return ListeningQueueActionPolicy.availability(
        itemID: item.serverItemId, episodeID: nil, category: item.category, nowPlaying: nowPlaying
      ).offersAddToUpNext
    }
  }
}

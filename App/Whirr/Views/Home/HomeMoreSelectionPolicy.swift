import AppModel
import Persistence

nonisolated enum HomeMoreSelectionAction: Hashable {
  case markAsFinished
  case removeFromContinueListening
  case download
  case removeDownload
  case resetProgress
  case addToUpNext

  var title: String {
    switch self {
    case .markAsFinished: MediaActionCopy.markAsFinished.title
    case .removeFromContinueListening:
      ItemContextMenuPresentation.progressEntry(.removeFromContinueListening).title
    case .download: MediaActionCopy.download.title
    case .removeDownload: MediaActionCopy.removeDownloads.title
    case .resetProgress: MediaActionCopy.resetProgress.title
    case .addToUpNext: MediaActionCopy.addToUpNext.title
    }
  }

  var batchAction: ItemBatchAction {
    switch self {
    case .markAsFinished: .markAsFinished
    case .removeFromContinueListening: .removeFromContinueListening
    case .download: .download
    case .removeDownload: .removeDownload
    case .resetProgress: .resetProgress
    case .addToUpNext: .addToUpNext
    }
  }

  static func removeFromShelfTitle(section: HomeMoreSection) -> String {
    ItemContextMenuPresentation.progressEntry(
      .removeFromContinueListening, usesEbookProgress: section == .continueReading
    ).title
  }
}

nonisolated enum HomeMoreSelectionPolicy {
  /// Only these shelves let a bulk action reshape the list the user is looking at. Recently Added
  /// and Latest Episodes are windows onto server state with no local bulk verb; Continue Series
  /// holds unstarted next books, where progress verbs are meaningless. Downloaded and Saved for
  /// Later route to their own destinations, which have their own selection.
  static func offersSelection(section: HomeMoreSection) -> Bool {
    switch section {
    case .continueListening, .continueReading: true
    case .continueSeries, .newEpisodes, .recentlyAdded, .downloaded, .savedForLater,
      .listeningStats, .smartLists:
      false
    }
  }

  static func capability(for item: HomeItem) -> ItemMediaCapability? {
    let capability = ItemMediaCapability.derive(
      category: item.category, hasReadableEbook: item.hasReadableEbook)
    return capability == .unsupportedDocument ? nil : capability
  }

  /// A title with no audio can only sit on Continue Reading, so its menu says so on any shelf;
  /// anything with audio keeps the listening wording outside the Continue Reading shelf.
  static func usesEbookProgress(for item: HomeItem, in section: HomeMoreSection) -> Bool {
    section == .continueReading || capability(for: item) == .ebook
  }

  static func downloadFormat(
    for item: HomeItem, requested: ItemDownloadFormat?
  ) -> ItemDownloadFormat? {
    capability(for: item)?.downloadFormat(requested: requested)
  }

  static func playbackStatus(_ item: HomeItem) -> ItemPlaybackStatus? {
    MediaProgressActionPolicy.playbackStatus(
      progressSeconds: item.progressSeconds,
      ebookProgress: item.ebookProgress,
      isFinished: item.isFinished)
  }

  static func accepts(
    _ action: HomeMoreSelectionAction,
    item: HomeItem,
    deviceAction: ItemContextMenuDownloadAction,
    nowPlaying: ListeningIdentity?,
    isHidden: Bool,
    isCurrentlyPlaying: Bool
  ) -> Bool {
    switch action {
    case .download:
      return capability(for: item)?.supportsDownload == true && deviceAction == .download
    case .removeDownload:
      return capability(for: item)?.supportsDownload == true && deviceAction == .remove
    case .markAsFinished:
      return MediaProgressActionPolicy.actions(for: playbackStatus(item))
        .contains(.markAsFinished)
    case .resetProgress:
      return MediaProgressActionPolicy.actions(for: playbackStatus(item)).contains(.resetProgress)
    case .removeFromContinueListening:
      return MediaProgressActionPolicy.actions(
        for: playbackStatus(item), isHidden: isHidden, isCurrentlyPlaying: isCurrentlyPlaying
      ).contains(.removeFromContinueListening)
    case .addToUpNext:
      return ListeningQueueActionPolicy.availability(
        itemID: item.serverItemId,
        episodeID: item.episodeID,
        category: item.category,
        nowPlaying: nowPlaying
      ).offersAddToUpNext
    }
  }
}

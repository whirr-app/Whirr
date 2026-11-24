import Foundation
import Persistence

/// A `DownloadIntents` wrapper that forwards to another implementation.
///
/// Every requirement's default here passes the call through unchanged. A decorator therefore
/// declares only the calls whose behaviour it changes, and adding a `DownloadIntents` method needs
/// one implementation rather than one per decorator.
public protocol DownloadIntentsDecorator: DownloadIntents {
  /// The intents behind this decorator. Read by the App's composition tests, which check the
  /// coordinator behind the wrappers.
  var wrapped: any DownloadIntents { get }
}

// MARK: - Passed through unchanged

extension DownloadIntentsDecorator {
  public func requestDownload(itemID: String) async throws {
    try await wrapped.requestDownload(itemID: itemID)
  }

  public func requestEbookDownload(itemID: String) async throws {
    try await wrapped.requestEbookDownload(itemID: itemID)
  }

  public func requestSupplementDownload(itemID: String, fileIno: String) async throws {
    try await wrapped.requestSupplementDownload(itemID: itemID, fileIno: fileIno)
  }

  public func requestEpisodeDownload(itemID: String, episodeID: String) async throws {
    try await wrapped.requestEpisodeDownload(itemID: itemID, episodeID: episodeID)
  }

  public func pauseEpisodeDownload(itemID: String, episodeID: String) async throws {
    try await wrapped.pauseEpisodeDownload(itemID: itemID, episodeID: episodeID)
  }

  public func resumeEpisodeDownload(itemID: String, episodeID: String) async throws {
    try await wrapped.resumeEpisodeDownload(itemID: itemID, episodeID: episodeID)
  }

  public func purgeEpisodeDownload(
    itemID: String, episodeID: String, source: DownloadPurgeSource
  ) async throws {
    try await wrapped.purgeEpisodeDownload(itemID: itemID, episodeID: episodeID, source: source)
  }

  public func pauseEbookDownload(itemID: String) async throws {
    try await wrapped.pauseEbookDownload(itemID: itemID)
  }

  public func resumeEbookDownload(itemID: String) async throws {
    try await wrapped.resumeEbookDownload(itemID: itemID)
  }

  public func purgeEbookDownload(itemID: String, source: DownloadPurgeSource) async throws {
    try await wrapped.purgeEbookDownload(itemID: itemID, source: source)
  }

  public func pauseItemDownload(itemID: String) async throws {
    try await wrapped.pauseItemDownload(itemID: itemID)
  }

  public func resumeItemDownload(itemID: String) async throws {
    try await wrapped.resumeItemDownload(itemID: itemID)
  }

  public func purgeItemDownload(itemID: String, source: DownloadPurgeSource) async throws {
    try await wrapped.purgeItemDownload(itemID: itemID, source: source)
  }

  public func purgeAllDownloads(source: DownloadPurgeSource) async throws {
    try await wrapped.purgeAllDownloads(source: source)
  }

  public func purgeTombstonedEpisodeDownloads(source: DownloadPurgeSource) async throws {
    try await wrapped.purgeTombstonedEpisodeDownloads(source: source)
  }

  public func isQueuePausedForLowDisk() async -> Bool {
    await wrapped.isQueuePausedForLowDisk()
  }
}

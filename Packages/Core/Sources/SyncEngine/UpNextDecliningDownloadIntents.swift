import Foundation
import Persistence

/// The decline writes a hand removal or a hand download makes for Up Next.
/// `ListeningQueueStore` is the production one.
public protocol UpNextDownloadDeclining: Sendable {
  /// See `ListeningQueueStore.declineDownloads`.
  func declineDownloads(itemID: String?, episodeID: String?, at date: Date) async throws
  func declineTombstonedDownloads(at date: Date) async throws
  func clearDownloadDecline(itemID: String, episodeID: String?) async throws
}

extension ListeningQueueStore: UpNextDownloadDeclining {}

/// Wraps the listener's download intents so Download Up Next respects hand actions.
/// A hand removal flags the Up Next entries it names, or the next foreground pass would
/// download them again; a hand download of an episode or a book clears the flag. Only hand
/// actions go through `AppDependencies.downloadIntents`; Download Up Next's own requests reach the
/// coordinator directly.
///
/// The decline is written before the purge, so a pass that already read its candidates still sees
/// it at request time. A decline is never rolled back, and its failure never fails the hand action.
public struct UpNextDecliningDownloadIntents: DownloadIntentsDecorator, Sendable {
  /// Read by the App's composition tests, which check the coordinator behind the wrappers.
  public let wrapped: any DownloadIntents
  private let declining: any UpNextDownloadDeclining
  private let now: @Sendable () -> Date

  public init(
    wrapping wrapped: any DownloadIntents,
    declining: any UpNextDownloadDeclining,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.wrapped = wrapped
    self.declining = declining
    self.now = now
  }

  /// How an audiobook is downloaded by hand. The coordinator refuses a whole-show request, so
  /// this never clears a show's episodes.
  public func requestDownload(itemID: String) async throws {
    try await wrapped.requestDownload(itemID: itemID)
    try? await declining.clearDownloadDecline(itemID: itemID, episodeID: nil)
  }

  public func requestEpisodeDownload(itemID: String, episodeID: String) async throws {
    try await wrapped.requestEpisodeDownload(itemID: itemID, episodeID: episodeID)
    try? await declining.clearDownloadDecline(itemID: itemID, episodeID: episodeID)
  }

  public func purgeEpisodeDownload(
    itemID: String, episodeID: String, source: DownloadPurgeSource
  ) async throws {
    if source.isHandRemoval {
      try? await declining.declineDownloads(itemID: itemID, episodeID: episodeID, at: now())
    }
    try await wrapped.purgeEpisodeDownload(itemID: itemID, episodeID: episodeID, source: source)
  }

  public func purgeItemDownload(itemID: String, source: DownloadPurgeSource) async throws {
    if source.isHandRemoval {
      try? await declining.declineDownloads(itemID: itemID, episodeID: nil, at: now())
    }
    try await wrapped.purgeItemDownload(itemID: itemID, source: source)
  }

  public func purgeAllDownloads(source: DownloadPurgeSource) async throws {
    if source.isHandRemoval {
      try? await declining.declineDownloads(itemID: nil, episodeID: nil, at: now())
    }
    try await wrapped.purgeAllDownloads(source: source)
  }

  /// Storage's "Reclaim removed episodes". The coordinator picks the rows, so the decline flags
  /// the queued entries by the same tombstone rule.
  public func purgeTombstonedEpisodeDownloads(source: DownloadPurgeSource) async throws {
    if source.isHandRemoval {
      try? await declining.declineTombstonedDownloads(at: now())
    }
    try await wrapped.purgeTombstonedEpisodeDownloads(source: source)
  }

}

import Foundation
import Persistence

/// The decline writes a hand removal or a hand download makes for smart lists.
/// `SmartListDownloadStore` is the production one.
public protocol SmartListDeclining: Sendable {
  /// Declines what auto-downloading lists want right now among the matching episodes; see
  /// `SmartListDownloadStore.declineWanted`.
  func declineWanted(itemID: String?, episodeID: String?, accountID: Int64?, at date: Date)
    async throws -> [SmartListEpisodeIdentity]
  func dropClaims(episodes: [SmartListEpisodeIdentity]) async throws
  func clearDecline(itemID: String, episodeID: String?) async throws
}

extension SmartListDownloadStore: SmartListDeclining {}

/// Wraps the listener's download intents so an auto-downloading smart list respects hand
/// actions. A hand removal declines the episodes the lists want right now, or
/// the next pass would download them again; a hand episode download clears that. Only hand
/// actions go through `AppDependencies.downloadIntents`, so the reconciler's own requests and
/// releases, which reach the coordinator directly, never decline.
///
/// The decline is written before the purge, so a pass already past its wanted-set read still
/// sees it at request time. Claims are dropped only once the purge has succeeded: a purge that
/// throws leaves the file and its claim, which the reconciler releases in the ordinary way. A
/// decline is never rolled back, and its failure never fails the hand action.
///
/// A whole-show podcast request is refused by the coordinator, so a hand `requestDownload`
/// clears nothing here; only the episode-scoped request does.
public struct SmartListDecliningDownloadIntents: DownloadIntentsDecorator, Sendable {
  /// Read by the App's composition tests, which check the coordinator behind the wrappers.
  public let wrapped: any DownloadIntents
  private let declining: any SmartListDeclining
  private let accountID: Int64?
  private let now: @Sendable () -> Date

  /// `accountID` nil declines native episodes only.
  public init(
    wrapping wrapped: any DownloadIntents,
    declining: any SmartListDeclining,
    accountID: Int64?,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.wrapped = wrapped
    self.declining = declining
    self.accountID = accountID
    self.now = now
  }

  public func requestEpisodeDownload(itemID: String, episodeID: String) async throws {
    try await wrapped.requestEpisodeDownload(itemID: itemID, episodeID: episodeID)
    try? await declining.clearDecline(itemID: itemID, episodeID: episodeID)
  }

  public func purgeEpisodeDownload(
    itemID: String, episodeID: String, source: DownloadPurgeSource
  ) async throws {
    try await declinedPurge(itemID: itemID, episodeID: episodeID, source: source) {
      try await wrapped.purgeEpisodeDownload(itemID: itemID, episodeID: episodeID, source: source)
    }
  }

  public func purgeItemDownload(itemID: String, source: DownloadPurgeSource) async throws {
    try await declinedPurge(itemID: itemID, episodeID: nil, source: source) {
      try await wrapped.purgeItemDownload(itemID: itemID, source: source)
    }
  }

  public func purgeAllDownloads(source: DownloadPurgeSource) async throws {
    try await declinedPurge(itemID: nil, episodeID: nil, source: source) {
      try await wrapped.purgeAllDownloads(source: source)
    }
  }

  private func declinedPurge(
    itemID: String?, episodeID: String?, source: DownloadPurgeSource,
    purge: () async throws -> Void
  ) async throws {
    guard source.isHandRemoval else {
      try await purge()
      return
    }
    let declined =
      (try? await declining.declineWanted(
        itemID: itemID, episodeID: episodeID, accountID: accountID, at: now())) ?? []
    try await purge()
    try? await declining.dropClaims(episodes: declined)
  }

}

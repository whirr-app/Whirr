import Foundation
import Persistence

/// The decline writes a hand removal or a hand download makes. `PinnedListStore` is the production
/// one.
public protocol PinnedListDeclining: Sendable {
  func decline(accountID: Int64, member: PinnedListMember, at date: Date) async throws
  func declineAll(accountID: Int64, at date: Date) async throws
  func clearDeclines(accountID: Int64, member: PinnedListMember) async throws
}

extension PinnedListStore: PinnedListDeclining {}

/// Wraps the listener's download intents so a pinned list respects hand actions. A hand removal
/// declines the member in every pin holding it (or the next pass would re-download it); a hand
/// download clears that. Only hand actions go through `AppDependencies.downloadIntents`, which is
/// why this sits there and not in the coordinator.
///
/// The decline is written after the purge succeeds, and its own failure never fails the purge.
public struct PinnedListDecliningDownloadIntents: DownloadIntentsDecorator, Sendable {
  /// Read by the App's composition tests, which check the coordinator behind the wrapper.
  public let wrapped: any DownloadIntents
  private let declining: any PinnedListDeclining
  private let accountID: Int64
  private let now: @Sendable () -> Date

  public init(
    wrapping wrapped: any DownloadIntents,
    declining: any PinnedListDeclining,
    accountID: Int64,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.wrapped = wrapped
    self.declining = declining
    self.accountID = accountID
    self.now = now
  }

  public func requestDownload(itemID: String) async throws {
    try await wrapped.requestDownload(itemID: itemID)
    try? await declining.clearDeclines(
      accountID: accountID, member: PinnedListMember(serverItemID: itemID, serverEpisodeID: nil))
  }

  public func requestEpisodeDownload(itemID: String, episodeID: String) async throws {
    try await wrapped.requestEpisodeDownload(itemID: itemID, episodeID: episodeID)
    try? await declining.clearDeclines(
      accountID: accountID, member: PinnedListMember(serverItemID: itemID, serverEpisodeID: episodeID))
  }

  public func purgeItemDownload(itemID: String, source: DownloadPurgeSource) async throws {
    try await wrapped.purgeItemDownload(itemID: itemID, source: source)
    await declineIfByHand(PinnedListMember(serverItemID: itemID, serverEpisodeID: nil), source: source)
  }

  public func purgeEpisodeDownload(
    itemID: String, episodeID: String, source: DownloadPurgeSource
  ) async throws {
    try await wrapped.purgeEpisodeDownload(itemID: itemID, episodeID: episodeID, source: source)
    await declineIfByHand(
      PinnedListMember(serverItemID: itemID, serverEpisodeID: episodeID), source: source)
  }

  public func purgeAllDownloads(source: DownloadPurgeSource) async throws {
    try await wrapped.purgeAllDownloads(source: source)
    guard source.isHandRemoval else { return }
    try? await declining.declineAll(accountID: accountID, at: now())
  }

  private func declineIfByHand(_ member: PinnedListMember, source: DownloadPurgeSource) async {
    guard source.isHandRemoval else { return }
    try? await declining.decline(accountID: accountID, member: member, at: now())
  }

}

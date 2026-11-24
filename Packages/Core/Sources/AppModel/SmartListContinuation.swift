import Foundation
import Persistence

/// `PlaybackContinuationSource` over the run row and the smart list reading.
///
/// `hasAvailableSource` is the caller's rule for "this list can show anything right now" (native
/// subscriptions on, or an account signed in). While it is false `currentRun()` is nil, the run row
/// stays, and completion plays Up Next. `reading` is a factory because the reading is built with
/// the native preference baked in.
public actor SmartListContinuation: PlaybackContinuationSource {
  private let runs: SmartListRunStore
  private let reading: @Sendable () -> SmartListEpisodesReading
  private let hasAvailableSource: @Sendable () async -> Bool
  /// The candidate `nextEpisode` last returned, so recording its start needs no second read.
  private var lastCandidate: SmartListCandidate?

  public init(
    runs: SmartListRunStore,
    reading: @escaping @Sendable () -> SmartListEpisodesReading,
    hasAvailableSource: @escaping @Sendable () async -> Bool
  ) {
    self.runs = runs
    self.reading = reading
    self.hasAvailableSource = hasAvailableSource
  }

  public func currentRun() async -> SmartListRunState? {
    guard let row = try? await runs.current(), await hasAvailableSource() else { return nil }
    return Self.state(row)
  }

  public func nextEpisode(
    after run: SmartListRunState, excluding: ListeningIdentity
  ) async throws -> SmartListCandidate? {
    var excluded: [(itemID: String, episodeID: String)] = []
    if let episodeID = excluding.episodeID { excluded.append((excluding.itemID, episodeID)) }
    let candidate = try await reading().nextEpisodes(
      listID: run.listID, after: run.anchorSortKey, excluding: excluded, count: 1
    ).first
    lastCandidate = candidate
    return candidate
  }

  public func endRun(reason: SmartListRunEndReason) async {
    try? await runs.end()
  }

  public func endRunUnlessAnchored(itemID: String, episodeID: String?) async {
    guard let row = try? await runs.current() else { return }
    if row.anchorItemID == itemID, row.anchorEpisodeID == episodeID { return }
    try? await runs.end()
  }

  public func recordListStart(itemID: String, episodeID: String, listID: Int64?) async -> Bool {
    let targetList: Int64
    if let listID {
      guard (try? await runs.begin(listID: listID)) != nil else { return false }
      targetList = listID
    } else {
      guard let row = try? await runs.current() else { return false }
      targetList = row.listId
    }
    let key = await sortKey(itemID: itemID, episodeID: episodeID, listID: targetList)
    return (try? await runs.setAnchor(itemID: itemID, episodeID: episodeID, sortKey: key)) ?? false
  }

  /// The started episode's place in the list. When it is not among the list's first 1,000 rows
  /// (or is no longer listed) the stored key is empty, which `nextEpisodes` treats as "from the
  /// top": the run still drains the list, it just does not resume mid-list.
  private func sortKey(itemID: String, episodeID: String, listID: Int64) async -> String {
    if let cached = lastCandidate, cached.itemID == itemID, cached.episodeID == episodeID {
      return cached.sortKey.encoded
    }
    let snapshot = try? await reading().fetchSnapshot(
      listID: listID, limit: SmartListEpisodesReading.maximumLimit)
    let match = snapshot?.episodes.first { $0.itemID == itemID && $0.episodeID == episodeID }
    return match?.sortKey.encoded ?? ""
  }

  private static func state(_ row: SmartListRunRecord) -> SmartListRunState {
    SmartListRunState(
      listID: row.listId, anchorItemID: row.anchorItemID, anchorEpisodeID: row.anchorEpisodeID,
      anchorSortKey: row.anchorSortKey.flatMap { SmartListSortKey(encoded: $0) })
  }
}

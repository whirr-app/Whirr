import Foundation
import Persistence

/// Where a run stands, as playback needs it: the list and the episode it last started.
public struct SmartListRunState: Sendable, Equatable {
  public let listID: Int64
  public let anchorItemID: String?
  public let anchorEpisodeID: String?
  /// Nil before the first list start succeeds, or when the stored key is not one this version wrote.
  public let anchorSortKey: SmartListSortKey?

  public init(
    listID: Int64, anchorItemID: String? = nil, anchorEpisodeID: String? = nil,
    anchorSortKey: SmartListSortKey? = nil
  ) {
    self.listID = listID
    self.anchorItemID = anchorItemID
    self.anchorEpisodeID = anchorEpisodeID
    self.anchorSortKey = anchorSortKey
  }
}

public enum SmartListRunEndReason: Sendable, Equatable {
  /// The list had no unfinished episode left; Up Next takes over.
  case listExhausted
  /// A start the listener asked for that is neither from the list nor of its anchor episode.
  case startedElsewhere
  case stoppedByListener
  case listDeleted
}

/// A list's own start, attached to the call sites that are the list's Play, one of its rows, or an
/// episode card opened from it.
public enum RunIntent: Sendable, Equatable {
  /// Begin a run of `listID` once the start succeeds.
  case begin(listID: Int64)
}

/// What plays before Up Next while a smart list run is active (ADR 0016). `PlaybackModel` asks it
/// when a title completes and tells it about every start, so the run's rules live in one place.
public protocol PlaybackContinuationSource: Sendable {
  /// The active run, or nil when there is none or its list has no available source (the row is
  /// kept, and completion plays Up Next).
  func currentRun() async -> SmartListRunState?
  /// The run's next unfinished episode, never `excluding` (the title that just finished, whose
  /// finished state may not be committed yet). Nil when the list is drained. Throws when the
  /// read failed, which is not the same as drained.
  func nextEpisode(
    after run: SmartListRunState, excluding: ListeningIdentity
  ) async throws -> SmartListCandidate?
  func endRun(reason: SmartListRunEndReason) async
  /// Ends the run unless the started identity is the run's stored anchor. Judged against the
  /// anchor row, never the asynchronously written bookmark.
  func endRunUnlessAnchored(itemID: String, episodeID: String?) async
  /// Records a successful list start. A non-nil `listID` begins a run of that list with this
  /// episode as its anchor; nil moves the active run's anchor. False when nothing was written.
  @discardableResult
  func recordListStart(itemID: String, episodeID: String, listID: Int64?) async -> Bool
}

/// Composition without Smart Lists: no run, nothing to end or record.
public struct NoOpPlaybackContinuationSource: PlaybackContinuationSource {
  public init() {}
  public func currentRun() async -> SmartListRunState? { nil }
  public func nextEpisode(
    after run: SmartListRunState, excluding: ListeningIdentity
  ) async throws -> SmartListCandidate? { nil }
  public func endRun(reason: SmartListRunEndReason) async {}
  public func endRunUnlessAnchored(itemID: String, episodeID: String?) async {}
  public func recordListStart(itemID: String, episodeID: String, listID: Int64?) async -> Bool {
    false
  }
}

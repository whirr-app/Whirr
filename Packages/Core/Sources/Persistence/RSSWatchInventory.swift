import Foundation

/// One inventory the Watch reported. `App` maps the wire selections to episode ids before calling
/// the store; unknown ids are dropped there, so every entry here names an `rssEpisode` row.
public struct RSSWatchInventory: Sendable, Equatable {
  public struct Entry: Sendable, Equatable {
    /// What the Watch says about one copy it was offered.
    public enum State: String, Sendable, Equatable, CaseIterable {
      /// Complete and admitted: the only evidence that makes a copy "On Watch".
      case ready
      /// Partially downloaded on the Watch. Reported so the phone shows "Sending", not
      /// "Delivered".
      case receiving
      /// A tombstone: the Watch deleted the copy (or never admitted it).
      case removed
      /// The Watch refuses this copy, e.g. its shared budget is full.
      case declined
    }

    public let episodeId: Int64
    public let revision: Int64
    public let state: State
    public let declineReason: RSSWatchDeclineReason?
    public let committedBytes: Int64?

    public init(
      episodeId: Int64, revision: Int64, state: State,
      declineReason: RSSWatchDeclineReason? = nil, committedBytes: Int64? = nil
    ) {
      self.episodeId = episodeId
      self.revision = revision
      self.state = state
      self.declineReason = declineReason
      self.committedBytes = committedBytes
    }
  }

  public let watchInstallID: String
  /// Monotonic per install; a sequence at or below the stored one is a late duplicate.
  public let sequence: UInt64
  /// The desired-set generation the Watch has seen. An inventory that acknowledges the current
  /// generation can prove a copy is gone by omitting it.
  public let acknowledgedGeneration: UInt64
  /// False while the Watch is signed out: owed copies wait instead of being re-sent.
  public let acceptsCopies: Bool
  public let entries: [Entry]
  public let budgetTotalBytes: Int64
  public let budgetUsedBytes: Int64
  public let observedAt: Date

  public init(
    watchInstallID: String,
    sequence: UInt64,
    acknowledgedGeneration: UInt64,
    acceptsCopies: Bool,
    entries: [Entry],
    budgetTotalBytes: Int64,
    budgetUsedBytes: Int64,
    observedAt: Date
  ) {
    self.watchInstallID = watchInstallID
    self.sequence = sequence
    self.acknowledgedGeneration = acknowledgedGeneration
    self.acceptsCopies = acceptsCopies
    self.entries = entries
    self.budgetTotalBytes = budgetTotalBytes
    self.budgetUsedBytes = budgetUsedBytes
    self.observedAt = observedAt
  }
}

/// What one inventory changed, for the publisher to re-offer and the UI to refresh.
public struct RSSWatchCopyInventoryOutcome: Sendable, Equatable {
  /// Rows whose state changed, ascending. An install replacement reports every row it deleted.
  public let changedEpisodeIds: [Int64]
  public let installReplaced: Bool

  public init(changedEpisodeIds: [Int64], installReplaced: Bool) {
    self.changedEpisodeIds = changedEpisodeIds
    self.installReplaced = installReplaced
  }
}

/// One emission of the phone's desired Watch set and the Watch's set state, for the UI projection.
/// `copies` is newest request first, the offer's order.
public struct RSSWatchCopyObservation: Sendable, Equatable {
  public let copies: [RSSWatchCopy]
  public let set: RSSWatchCopySetState

  public init(copies: [RSSWatchCopy], set: RSSWatchCopySetState) {
    self.copies = copies
    self.set = set
  }
}

public enum NativeEpisodeServerSaveBatchCopy {
  /// Client guard, not an Audiobookshelf limit.
  public static let maximumEpisodesPerBatch = 50
  public static let batchAction = MediaActionCopy.saveToServer.title
  public static let cancelAction = "Cancel"

  public static func limitExceeded(selected: Int) -> String {
    "Select up to \(maximumEpisodesPerBatch) episodes to save at once. \(selected) are selected."
  }

  public static func progress(completed: Int, total: Int) -> String {
    "Saving \(completed) of \(total) to Audiobookshelf\u{2026}"
  }

  public static func cancelling(completed: Int, total: Int) -> String {
    "Cancelling after \(completed) of \(total)\u{2026}"
  }

  public struct Tally: Sendable, Equatable {
    public var requested: Int
    public var alreadySaved: Int
    public var inProgress: Int
    public var skipped: Int
    public var failed: Int
    public var uncertain: Int
    public var notAttempted: Int
    public var cancelled: Bool

    public init(
      requested: Int = 0,
      alreadySaved: Int = 0,
      inProgress: Int = 0,
      skipped: Int = 0,
      failed: Int = 0,
      uncertain: Int = 0,
      notAttempted: Int = 0,
      cancelled: Bool = false
    ) {
      self.requested = requested
      self.alreadySaved = alreadySaved
      self.inProgress = inProgress
      self.skipped = skipped
      self.failed = failed
      self.uncertain = uncertain
      self.notAttempted = notAttempted
      self.cancelled = cancelled
    }
  }

  public static func summary(_ tally: Tally) -> String {
    var clauses: [String] = []
    if tally.alreadySaved > 0 {
      clauses.append("\(tally.alreadySaved) already saved")
    }
    if tally.requested > 0 {
      let hasOtherClauses =
        tally.alreadySaved > 0 || tally.inProgress > 0 || tally.skipped > 0
        || tally.failed > 0 || tally.uncertain > 0 || tally.notAttempted > 0
      let prefix = tally.alreadySaved > 0 || tally.cancelled ? "requested" : "Requested"
      let requested =
        hasOtherClauses || tally.cancelled
        ? "\(prefix) \(tally.requested)"
        : "\(prefix) \(tally.requested) \(episodeNoun(for: tally.requested))"
      clauses.append(requested)
    }
    if tally.inProgress > 0 {
      clauses.append("\(tally.inProgress) in progress")
    }
    if tally.skipped > 0 {
      clauses.append("\(tally.skipped) skipped")
    }
    if tally.failed > 0 {
      clauses.append("\(tally.failed) failed")
    }
    if tally.uncertain > 0 {
      clauses.append("\(tally.uncertain) needs review")
    }
    if tally.notAttempted > 0 {
      clauses.append("\(tally.notAttempted) not attempted")
    }

    guard clauses.isEmpty == false else {
      return tally.cancelled ? "Cancelled: Nothing to save" : "Nothing to save"
    }
    let summary = clauses.joined(separator: "; ")
    return tally.cancelled ? "Cancelled: \(summary)" : summary
  }

  public static func allConfirmed(count: Int) -> String {
    count == 1 ? "Saved on server" : "Saved \(count) episodes on server"
  }

  public static func progressAccessibilityLabel(completed: Int, total: Int) -> String {
    "Saving \(completed) of \(total) \(episodeNoun(for: total)) to Audiobookshelf"
  }

  private static func episodeNoun(for count: Int) -> String {
    count == 1 ? "episode" : "episodes"
  }
}

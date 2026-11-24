import Foundation

/// What a transcript session's feed does next. Pure, so
/// the decisions are tested apart from the analyser.
///
/// The feed stays `leadSeconds` ahead of what the analyser has finalised: enough to keep it busy
/// (measured: one stall in three hour-long runs at 30 s), little enough that a hold idles it within
/// about a second and a checkpoint discards at most one lead. With a full lead queued and nothing
/// final for `stallSeconds`, the lead widens by one.
nonisolated struct TranscriptFeedPacer: Sendable {
  enum Decision: Sendable, Equatable {
    /// Hand the analyser the next read.
    case feed
    /// A full lead is queued: wait for final results.
    case waitForProgress
    /// The coordinator holds the session: feed nothing.
    case hold
  }

  let leadSeconds: Double
  let stallSeconds: Double

  private(set) var stalls = 0
  private var extraLead: Double = 0
  private var lastFinalized: Double = 0
  private var lastProgressAt: Double?

  init(leadSeconds: Double = 30, stallSeconds: Double = 2) {
    self.leadSeconds = leadSeconds
    self.stallSeconds = stallSeconds
  }

  /// `fed` and `finalized` are file seconds; `now` is seconds since the session started.
  mutating func decide(at now: Double, fed: Double, finalized: Double, isHeld: Bool) -> Decision {
    if isHeld {
      // Time held is not time stalled.
      lastProgressAt = nil
      return .hold
    }
    if finalized > lastFinalized || lastProgressAt == nil {
      lastFinalized = max(lastFinalized, finalized)
      lastProgressAt = now
    }
    if fed - finalized < leadSeconds + extraLead { return .feed }
    if let lastProgressAt, now - lastProgressAt >= stallSeconds {
      stalls += 1
      extraLead += leadSeconds
      self.lastProgressAt = now
      return .feed
    }
    return .waitForProgress
  }
}

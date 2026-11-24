import CoreSupport
import Foundation

/// What `persistTick` did with one progress tick, and why it could not persist it if it didn't.
/// Shares the `WHIRRSYNC` stream with `DrainCadenceTrace`, read the same way:
///
///     log stream --predicate 'eventMessage CONTAINS "WHIRRSYNC"'
///
/// States the branch taken so a dropped tick can be traced without reading the code. Only the
/// abnormal is logged (`isNoteworthy`): an ordinary tick persists every 15 s of every listen and
/// would bury the ones that matter.
public enum PlaybackTickTrace {
  public static let prefix = "WHIRRSYNC"

  /// Which of `persistTick`'s branches handled, or tried to handle, the tick, in the order they
  /// are tried.
  public enum Route: String, Equatable, Sendable {
    /// The verified online target carried over from the preceding accepted tick.
    case cachedOnline = "cached-online"
    /// A locally-active (downloaded/offline) session, via `recordLocalTick`.
    case local
    /// A freshly-resolved online session, via `recordNextTick`.
    case online
    /// The safety net: position only, no session at all (`recordSessionlessTick`).
    case sessionless
    /// A position-only write for a final tick emitted before an item switch displaced its session.
    case displaced
  }

  /// Why nothing durable was written.
  public enum DropReason: String, Equatable, Sendable {
    case noAccountRow = "no-account-row"
    case noItemRow = "no-item-row"
    case noEpisodeRow = "no-episode-row"
    /// Every branch that applied threw. The only outcome where live listening is lost.
    case everyWriteFailed = "write-failed"
    /// A straggler for something this device is not playing, dropped on purpose (see
    /// `persistSessionlessTick`).
    case notPlayingThisItem = "not-playing"
    /// The `ABS_VARIANT` device-experiment scaffolding suppressed the net's write.
    case suppressedByVariant = "variant-suppressed"
  }

  public enum Outcome: Equatable, Sendable {
    case persisted(Route)
    case dropped(DropReason)
  }

  /// Carries item/episode identifiers and position only: no URL, token, header or session id
  /// (SECURITY.md §7).
  public struct Record: Equatable, Sendable {
    public let outcome: Outcome
    /// Branches that were tried and threw before the outcome above was reached, in try order.
    public let failedRoutes: [Route]
    public let itemID: String
    public let episodeID: String?
    public let position: Double

    public init(
      outcome: Outcome, failedRoutes: [Route], itemID: String, episodeID: String?, position: Double
    ) {
      self.outcome = outcome
      self.failedRoutes = failedRoutes
      self.itemID = itemID
      self.episodeID = episodeID
      self.position = position
    }

    /// Anything other than an ordinary branch or a normal item-switch straggler. Reaching the
    /// sessionless net counts, because getting there at all means a session died underneath live
    /// audio.
    public var isNoteworthy: Bool {
      if failedRoutes.isEmpty == false { return true }
      switch outcome {
      case .persisted(let route): return route == .sessionless
      case .dropped: return true
      }
    }
  }

  public static func line(_ record: Record) -> String {
    let verdict: String
    switch record.outcome {
    case .persisted(let route): verdict = "outcome=persisted route=\(route.rawValue)"
    case .dropped(let reason): verdict = "outcome=dropped reason=\(reason.rawValue)"
    }
    let failed =
      record.failedRoutes.isEmpty
      ? "none" : record.failedRoutes.map(\.rawValue).joined(separator: ",")
    return
      "\(prefix) tick \(verdict) failed=\(failed) item=\(record.itemID) episode=\(record.episodeID ?? "none") position=\(String(format: "%.1f", record.position))"
  }

  static func emit(_ record: Record) {
    #if DEBUG
      guard record.isNoteworthy else { return }
      DeviceTraceLog.emit(line(record))
    #endif
  }
}

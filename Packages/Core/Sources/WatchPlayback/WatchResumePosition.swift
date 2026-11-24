import Foundation

/// Chooses where the Watch starts or resumes a title. The server is the single source of truth:
/// the newest listen wins, so listening on another device after the Watch last played moves the
/// Watch forward (or back) instead of the Watch resuming from its own stale position.
public enum WatchResumePosition {
  public struct Candidate: Sendable, Equatable {
    public let position: Double
    /// When this position was last chosen by listening or a user seek; `nil` when unknown.
    public let listenedAt: Date?
    /// The title was finished at this position; playing it again starts from the beginning.
    public let finished: Bool

    public init(position: Double, listenedAt: Date?, finished: Bool = false) {
      self.position = position
      self.listenedAt = listenedAt
      self.finished = finished
    }
  }

  /// Positions within this distance are the same place. The Watch's own upload reaches the server
  /// after its last listen, and that later timestamp must not read as listening elsewhere.
  public static let samePlaceTolerance: Double = 2

  /// A confirmed handoff is the phone's live position and always wins. Otherwise the newest of the
  /// Watch's own candidates is weighed against shared progress, and a winner that finished the
  /// title, here or elsewhere, starts it again from 0.
  public static func start(handoff: Double?, local: [Candidate], shared: Candidate?) -> Double {
    if let handoff { return handoff }
    let newestLocal = local.max { ($0.listenedAt ?? .distantPast) < ($1.listenedAt ?? .distantPast) }
    guard let newestLocal else { return shared.map(replayPosition) ?? 0 }
    if let shared, sharedSupersedes(local: newestLocal, shared: shared) { return replayPosition(shared) }
    return replayPosition(newestLocal)
  }

  private static func replayPosition(_ candidate: Candidate) -> Double {
    candidate.finished ? 0 : candidate.position
  }

  /// Whether shared progress records listening after the Watch's own and somewhere else. An undated
  /// Watch position defers to dated shared progress; undated shared progress never overrides.
  public static func sharedSupersedes(local: Candidate, shared: Candidate?) -> Bool {
    guard let shared, let sharedAt = shared.listenedAt,
      abs(shared.position - local.position) > samePlaceTolerance
    else { return false }
    guard let localAt = local.listenedAt else { return true }
    return sharedAt > localAt
  }
}

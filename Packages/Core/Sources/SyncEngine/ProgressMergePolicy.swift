import Foundation

/// Deterministic conflict resolution between a persisted progress row for one identity and an
/// incoming observation of that same identity: a pulled server row or a background player tick.
/// Pure decision logic (ARCHITECTURE.md §7, "Progress conflict identity is durable"): no I/O, no
/// mutable state, so a fresh instance after relaunch reaches the same decision for the same
/// inputs. Mapping wire DTOs and DB records to the value types below is the caller's job.
public struct ProgressMergePolicy: Sendable {
  public init() {}

  /// Fixed origin-key sentinel for server-pulled observations. Local
  /// observations use the account's persisted, never-regenerated client UUID instead.
  public static let serverOriginKey = "server"

  /// What the caller should do with `incoming` relative to the persisted row.
  public enum Decision: Sendable, Equatable {
    /// Overwrite the persisted field with `incoming`'s value.
    case applyServer
    /// Discard `incoming`; the persisted field is unchanged.
    case keepLocal
    /// A zero-position guard fired: don't overwrite, but record a conflict. The persisted
    /// (local) value stays visible pending resolution.
    case needsResolution
    /// `incoming` is a same-device observation whose captured sequence predates the persisted
    /// row's. Rejected outright, nothing changes.
    case rejectStale
  }

  /// Field-level outcomes for one pulled row. Audio position, ebook position, and the shared
  /// item-wide finish flag are independent: a single pull may apply some fields, retain others,
  /// and record a resolution for a third.
  public struct CompositeDecision: Sendable, Equatable {
    public let audioPosition: Decision
    public let ebookPosition: Decision
    public let sharedFinish: Decision

    public init(
      audioPosition: Decision,
      ebookPosition: Decision,
      sharedFinish: Decision
    ) {
      self.audioPosition = audioPosition
      self.ebookPosition = ebookPosition
      self.sharedFinish = sharedFinish
    }
  }

  /// Alternate name for callers that describe the policy output as a result rather than a
  /// decision.
  public typealias CompositeResult = CompositeDecision

  /// The persisted progress row being merged into. The scalar fields are the audio surface.
  /// Ebook fields and pending-write flags are separate so an unacknowledged operation for one
  /// medium cannot protect a pull for another.
  public struct CurrentState: Sendable, Equatable {
    public var currentTime: TimeInterval
    public var ebookProgress: Double?
    public var readingPositionJSON: String?
    public var ebookLocation: String?
    public var isFinished: Bool
    public var serverUpdatedAt: Date?
    public var localSequence: Int64
    /// The account's persisted client UUID if this row's last writer was local, or the fixed
    /// `serverOriginKey` sentinel if a pull last won. Never regenerated on relaunch.
    public var originKey: String
    /// True while an outbox operation writing the audio position or shared finish is still
    /// unacknowledged by the server. Ebook pending state is not folded into it.
    public var hasUnacknowledgedAudioOperation: Bool
    /// True while an ebook position operation is still unacknowledged by the server.
    public var hasUnacknowledgedEbookOperation: Bool
    /// True while a shared-finish operation is still unacknowledged by the server.
    public var hasUnacknowledgedFinishOperation: Bool

    /// `hasUnacknowledgedLocalOperation` is a row-level pending bit that protects audio and the
    /// shared finish flag. Prefer the three field-scoped bits.
    public init(
      currentTime: TimeInterval,
      isFinished: Bool,
      serverUpdatedAt: Date?,
      localSequence: Int64,
      originKey: String,
      hasUnacknowledgedLocalOperation: Bool = false,
      ebookProgress: Double? = nil,
      readingPositionJSON: String? = nil,
      ebookLocation: String? = nil,
      hasUnacknowledgedAudioOperation: Bool? = nil,
      hasUnacknowledgedEbookOperation: Bool = false,
      hasUnacknowledgedFinishOperation: Bool? = nil
    ) {
      self.currentTime = currentTime
      self.ebookProgress = ebookProgress
      self.readingPositionJSON = readingPositionJSON
      self.ebookLocation = ebookLocation
      self.isFinished = isFinished
      self.serverUpdatedAt = serverUpdatedAt
      self.localSequence = localSequence
      self.originKey = originKey
      self.hasUnacknowledgedAudioOperation =
        hasUnacknowledgedAudioOperation ?? hasUnacknowledgedLocalOperation
      self.hasUnacknowledgedEbookOperation = hasUnacknowledgedEbookOperation
      self.hasUnacknowledgedFinishOperation =
        hasUnacknowledgedFinishOperation ?? hasUnacknowledgedLocalOperation
    }

    /// Row-level spelling for audio callers. Excludes ebook pending work, since the two media
    /// positions have independent protection scopes.
    public var hasUnacknowledgedLocalOperation: Bool {
      hasUnacknowledgedAudioOperation || hasUnacknowledgedFinishOperation
    }
  }

  /// A new observation being merged against `CurrentState`: a pulled server row, or a
  /// same-device player/reader mutation. `readingPositionJSON` is accepted only for a local
  /// observation; a server observation has no locator JSON to fabricate from a fraction.
  public struct IncomingObservation: Sendable, Equatable {
    public var currentTime: TimeInterval
    public var ebookProgress: Double?
    public var ebookLocation: String?
    public var readingPositionJSON: String?
    public var isFinished: Bool
    public var serverUpdatedAt: Date?
    /// `serverOriginKey` for a pulled row, or this device's persisted client UUID for a
    /// same-device observation.
    public var originKey: String
    /// The local sequence captured at read time, present only for same-device observations (ticks,
    /// local resets). Its presence, not `originKey`, marks local origin: a same-device write is
    /// ordered by sequence whatever origin key it carries.
    public var localSequence: Int64?
    /// Reset evidence for a server observation: the server row this device last observed no
    /// longer exists, derived from server row identity, never a timestamp. Applies the observation
    /// without the server clock (an absent row has none) but never outranks an unacknowledged
    /// local write.
    public var signalsExplicitResetOrUnfinished: Bool

    public init(
      currentTime: TimeInterval,
      isFinished: Bool,
      serverUpdatedAt: Date?,
      originKey: String,
      localSequence: Int64? = nil,
      signalsExplicitResetOrUnfinished: Bool = false,
      ebookProgress: Double? = nil,
      ebookLocation: String? = nil,
      readingPositionJSON: String? = nil
    ) {
      self.currentTime = currentTime
      self.ebookProgress = ebookProgress
      self.ebookLocation = ebookLocation
      self.readingPositionJSON = readingPositionJSON
      self.isFinished = isFinished
      self.serverUpdatedAt = serverUpdatedAt
      self.originKey = originKey
      self.localSequence = localSequence
      self.signalsExplicitResetOrUnfinished = signalsExplicitResetOrUnfinished
    }

    public var hasEbookObservation: Bool {
      ebookProgress != nil || ebookLocation != nil || readingPositionJSON != nil
    }
  }

  /// Zero-position guard thresholds for audio. The ebook thresholds are separate because they
  /// compare fractions rather than seconds.
  private static let zeroPositionCeiling: TimeInterval = 5
  private static let substantialLocalFloor: TimeInterval = 60
  private static let substantialLocalFraction: Double = 0.02

  /// Ebook zero-position thresholds. Product choices, not values in the wire contract; the
  /// rationale is recorded as D33 in ARCHITECTURE.md.
  private static let zeroEbookProgressCeiling: Double = 0.005
  private static let substantialLocalEbookProgressFloor: Double = 0.02

  /// Resolves the audio position and finish flag at row level. `duration` is the item's known
  /// total duration, used only for the audio zero-position guard; pass `nil` when unknown.
  public func resolve(
    current: CurrentState,
    incoming: IncomingObservation,
    duration: TimeInterval? = nil
  ) -> Decision {
    let currentCandidate = OrderingCandidate(
      position: current.currentTime,
      isFinished: current.isFinished,
      serverUpdatedAt: current.serverUpdatedAt,
      originKey: current.originKey)
    let incomingCandidate = OrderingCandidate(
      position: incoming.currentTime,
      isFinished: incoming.isFinished,
      serverUpdatedAt: incoming.serverUpdatedAt,
      originKey: incoming.originKey)

    return resolveOrdered(
      current: currentCandidate,
      incoming: incomingCandidate,
      currentLocalSequence: current.localSequence,
      incomingLocalSequence: incoming.localSequence,
      hasUnacknowledgedLocalOperation: current.hasUnacknowledgedLocalOperation,
      hasResetEvidence: hasResetEvidence(current: current, incoming: incoming),
      guardFired: audioZeroPositionGuardFires(
        current: current, incoming: incoming, duration: duration))
  }

  /// Resolves the ebook position using the same local-sequence, pending-write, server-clock, and
  /// deterministic tie-break primitives as the audio policy. A missing ebook fraction and a
  /// present server location still constitute an ebook observation; the missing fraction is not
  /// replaced with a fabricated local locator.
  public func resolveEbook(
    current: CurrentState,
    incoming: IncomingObservation
  ) -> Decision {
    guard incoming.hasEbookObservation else { return .keepLocal }

    let currentCandidate = OrderingCandidate(
      position: current.ebookProgress ?? 0,
      isFinished: current.isFinished,
      serverUpdatedAt: current.serverUpdatedAt,
      originKey: current.originKey)
    let incomingCandidate = OrderingCandidate(
      position: incoming.ebookProgress ?? 0,
      isFinished: incoming.isFinished,
      serverUpdatedAt: incoming.serverUpdatedAt,
      originKey: incoming.originKey)

    return resolveOrdered(
      current: currentCandidate,
      incoming: incomingCandidate,
      currentLocalSequence: current.localSequence,
      incomingLocalSequence: incoming.localSequence,
      hasUnacknowledgedLocalOperation: current.hasUnacknowledgedEbookOperation,
      hasResetEvidence: hasResetEvidence(current: current, incoming: incoming),
      guardFired: ebookZeroPositionGuardFires(current: current, incoming: incoming))
  }

  /// Resolves audio position, ebook position, and the item-wide finish flag independently. The
  /// caller must pass the complete result to one Persistence transaction; no field is allowed to
  /// drag another field across the merge boundary.
  public func resolveComposite(
    current: CurrentState,
    incoming: IncomingObservation,
    duration: TimeInterval? = nil
  ) -> CompositeDecision {
    CompositeDecision(
      audioPosition: resolve(current: current, incoming: incoming, duration: duration),
      ebookPosition: resolveEbook(current: current, incoming: incoming),
      sharedFinish: resolveSharedFinish(current: current, incoming: incoming)
    )
  }

  /// The shared finish flag has its own pending-write scope and ordering decision. Its tie-break
  /// uses the audio position, and it never infers finish from either position reaching 1.0 or
  /// an audio duration.
  private func resolveSharedFinish(
    current: CurrentState,
    incoming: IncomingObservation
  ) -> Decision {
    let currentCandidate = OrderingCandidate(
      position: current.currentTime,
      isFinished: current.isFinished,
      serverUpdatedAt: current.serverUpdatedAt,
      originKey: current.originKey)
    let incomingCandidate = OrderingCandidate(
      position: incoming.currentTime,
      isFinished: incoming.isFinished,
      serverUpdatedAt: incoming.serverUpdatedAt,
      originKey: incoming.originKey)

    return resolveOrdered(
      current: currentCandidate,
      incoming: incomingCandidate,
      currentLocalSequence: current.localSequence,
      incomingLocalSequence: incoming.localSequence,
      hasUnacknowledgedLocalOperation: current.hasUnacknowledgedFinishOperation,
      hasResetEvidence: hasResetEvidence(current: current, incoming: incoming),
      guardFired: false)
  }

  private func resolveOrdered(
    current: OrderingCandidate,
    incoming: OrderingCandidate,
    currentLocalSequence: Int64,
    incomingLocalSequence: Int64?,
    hasUnacknowledgedLocalOperation: Bool,
    hasResetEvidence: Bool,
    guardFired: Bool
  ) -> Decision {
    // Same-device observations (ticks, explicit local resets) are ordered strictly by the
    // device's own monotonic sequence, never by wall clock or server timestamp. So a legitimate
    // backward user reset applies and a stale tick is rejected.
    if let capturedSequence = incomingLocalSequence {
      return capturedSequence < currentLocalSequence ? .rejectStale : .applyServer
    }

    // From here `incoming` is server-origin. An unacknowledged local write outranks any pull
    // until the server has actually seen it. The caller supplies this bit per field.
    if hasUnacknowledgedLocalOperation {
      return .keepLocal
    }

    // Reset evidence is structural, not temporal: an absent row has no timestamp, and a recreated
    // row is newer by construction. It therefore wins without the clock, and before the guard it
    // exists to excuse.
    if hasResetEvidence {
      return .applyServer
    }

    // Zero-position guards run before the server clock: a suspicious reset remains visible and
    // becomes an explicit resolution even when the server's timestamp is newer.
    if guardFired {
      return .needsResolution
    }

    return candidateWins(incoming, over: current) ? .applyServer : .keepLocal
  }

  private func candidateWins(
    _ incoming: OrderingCandidate,
    over current: OrderingCandidate
  ) -> Bool {
    MergeOrderKey(incoming) > MergeOrderKey(current)
  }

  /// Either form of reset evidence. The row-identity form arrives on the observation; the
  /// unfinished transition is decided here from the two rows. The server forces `currentTime` to 0
  /// when a finished row is marked not finished, so "mark as not finished" elsewhere arrives as a
  /// near-zero, newer, unfinished row. The local finish must be one the server has seen, which the
  /// caller's pending-finish bit rules on first.
  private func hasResetEvidence(
    current: CurrentState,
    incoming: IncomingObservation
  ) -> Bool {
    if incoming.signalsExplicitResetOrUnfinished { return true }
    guard current.isFinished, incoming.isFinished == false,
      incoming.localSequence == nil,
      let currentUpdate = current.serverUpdatedAt,
      let incomingUpdate = incoming.serverUpdatedAt
    else { return false }
    return incomingUpdate > currentUpdate
  }

  private func audioZeroPositionGuardFires(
    current: CurrentState,
    incoming: IncomingObservation,
    duration: TimeInterval?
  ) -> Bool {
    guard incoming.currentTime <= Self.zeroPositionCeiling,
      !incoming.signalsExplicitResetOrUnfinished
    else { return false }

    let aboveAbsoluteFloor = current.currentTime > Self.substantialLocalFloor
    let aboveFractionFloor: Bool
    if let duration, duration > 0 {
      aboveFractionFloor = (current.currentTime / duration) > Self.substantialLocalFraction
    } else {
      aboveFractionFloor = true
    }
    return aboveAbsoluteFloor && aboveFractionFloor
  }

  private func ebookZeroPositionGuardFires(
    current: CurrentState,
    incoming: IncomingObservation
  ) -> Bool {
    guard let incomingProgress = incoming.ebookProgress,
      incomingProgress <= Self.zeroEbookProgressCeiling,
      let currentProgress = current.ebookProgress,
      currentProgress > Self.substantialLocalEbookProgressFloor,
      !incoming.signalsExplicitResetOrUnfinished
    else { return false }
    return true
  }
}

/// The values needed by all of the policy's ordering paths. Keeping the clock and tie-break
/// comparison here prevents audio and ebook policies from drifting apart.
private struct OrderingCandidate: Sendable, Equatable {
  let position: Double
  let isFinished: Bool
  let serverUpdatedAt: Date?
  let originKey: String
}

extension ProgressMergePolicy {
  /// The merge precedence over two server-origin observations: the server clock first, then
  /// `TieBreakKey`. `candidateWins` is exactly "the incoming key is greater", and duplicate-row
  /// resolution extends this same key rather than restating its prefix.
  struct MergeOrderKey: Comparable, Sendable, Equatable {
    let serverUpdatedAt: Date?
    private let tieBreak: TieBreakKey

    /// `position` is optional so a row that omits its audio position still orders below a row
    /// that reports one; the merge itself always supplies a value.
    init(serverUpdatedAt: Date?, isFinished: Bool, position: Double?, originKey: String) {
      self.serverUpdatedAt = serverUpdatedAt
      self.tieBreak = TieBreakKey(
        isFinished: isFinished, position: position, originKey: originKey)
    }

    fileprivate init(_ candidate: OrderingCandidate) {
      self.init(
        serverUpdatedAt: candidate.serverUpdatedAt,
        isFinished: candidate.isFinished,
        position: candidate.position,
        originKey: candidate.originKey)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
      switch (lhs.serverUpdatedAt, rhs.serverUpdatedAt) {
      case (.some(let left), .some(let right)) where left != right:
        return left < right
      case (.none, .some):
        return true
      case (.some, .none):
        return false
      default:
        // Equal timestamps (or both nil) fall to the deterministic tie-break.
        return lhs.tieBreak < rhs.tieBreak
      }
    }
  }
}

/// The tie-break: `(isFinished, position, originKey)`, in priority order.
/// Finished ranks above unfinished; later position ranks above earlier, with an absent position
/// below any value; origin key breaks any remaining tie. A pure, stateless total order: the same
/// two keys always compare the same way, regardless of which side of a comparison they appear on.
struct TieBreakKey: Comparable {
  let isFinished: Bool
  let position: Double?
  let originKey: String

  static func < (lhs: TieBreakKey, rhs: TieBreakKey) -> Bool {
    if lhs.isFinished != rhs.isFinished { return !lhs.isFinished && rhs.isFinished }
    if lhs.position != rhs.position {
      switch (lhs.position, rhs.position) {
      case (.some(let left), .some(let right)): return left < right
      case (.none, .some): return true
      case (.some, .none), (.none, .none): return false
      }
    }
    return lhs.originKey < rhs.originKey
  }
}

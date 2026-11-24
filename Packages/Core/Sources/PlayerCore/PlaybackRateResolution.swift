/// The pure playback-rate policy for one title: a Focus speed, when one is on and applies to the
/// title, wins over an explicit title override, which wins over the global default, which wins
/// over the normal `1.0×` fallback.
///
/// An override equal to the current global default is still a pin that a later global change must
/// not move, so persistence represents inheritance with no row, not an equal-valued one.
///
/// Persistence carries the same `10...60` step bound independently: the dependency graph stops it
/// importing PlayerCore, so the constants are not shared.
public struct PlaybackRateResolution: Sendable, Equatable {
  /// Supported playback rates, inclusive. Taken from the reducer rather than restated: the reducer
  /// is what actually clamps `.setRate`, so a second literal here could disagree with the only
  /// bound the engine enforces.
  public static let supportedRateRange = PlayerReducer.supportedRateRange
  /// The persisted twentieths representation of `supportedRateRange`, inclusive.
  public static let supportedStepRange: ClosedRange<Int> = 10...60
  public static let defaultRate = 1.0
  public static let defaultStep = 20

  private static let stepsPerRate = 20.0

  /// The rate selected by the Focus/override/global/fallback policy.
  public let effectiveRate: Double

  /// Whether `effectiveRate` came from the Focus speed. False when there is no valid Focus speed,
  /// or when the Focus skips this title because it has its own speed.
  public let appliesFocusSpeed: Bool

  /// The selected rate in the representation used by the persistence boundary.
  public var effectiveStep: Int {
    Self.step(forRate: effectiveRate) ?? Self.defaultStep
  }

  /// Resolves a persisted title override against the global default. Invalid persisted values are
  /// rejected, not clamped: a corrupt row inherits the global default instead of becoming a
  /// different pin. Valid global values are normalized to exact twentieths.
  ///
  /// An invalid Focus speed means no Focus speed, never a clamp, because `.load` does not clamp.
  /// A corrupt override row counts as no own speed, so a Focus that skips titles with their own
  /// speed still applies.
  public init(overrideStep: Int?, globalRate: Double?, focusSpeed: FocusSpeed? = nil) {
    let overrideRate = overrideStep.flatMap(Self.rate(forStep:))
    let validGlobalRate = globalRate.flatMap(Self.normalizedRate)
    let focusRate = focusSpeed.flatMap { focus -> Double? in
      if focus.skipsTitlesWithOwnSpeed, overrideRate != nil { return nil }
      return Self.normalizedRate(focus.rate)
    }
    self.effectiveRate = focusRate ?? overrideRate ?? validGlobalRate ?? Self.defaultRate
    self.appliesFocusSpeed = focusRate != nil
  }

  /// Convenience initializer for callers that already have a rate rather than a persisted step.
  /// The same validation and normalization rules apply before the override participates in
  /// resolution.
  public init(overrideRate: Double?, globalRate: Double?, focusSpeed: FocusSpeed? = nil) {
    self.init(
      overrideStep: overrideRate.flatMap(Self.step(forRate:)),
      globalRate: globalRate,
      focusSpeed: focusSpeed)
  }

  /// Converts a persisted twentieths step to a supported rate. Invalid stored steps are rejected.
  public static func rate(forStep step: Int) -> Double? {
    guard supportedStepRange.contains(step) else { return nil }
    return Double(step) / stepsPerRate
  }

  /// Converts a rate to its exact twentieths step. Rates inside the supported range are rounded
  /// to the nearest representable step; non-finite and out-of-range values are rejected.
  public static func step(forRate rate: Double) -> Int? {
    guard rate.isFinite, supportedRateRange.contains(rate) else { return nil }
    let step = Int((rate * stepsPerRate).rounded())
    guard supportedStepRange.contains(step) else { return nil }
    return step
  }

  /// Returns the supported twentieths-normalized form of a rate, or nil when the rate is invalid.
  public static func normalizedRate(_ rate: Double) -> Double? {
    step(forRate: rate).flatMap(Self.rate(forStep:))
  }
}

/// A temporary speed set by a Focus filter while that Focus is on. It is never persisted; the App
/// holds the delivered value and hands it to the rate coordinator.
public struct FocusSpeed: Sendable, Equatable {
  /// The requested rate, validated by `PlaybackRateResolution` when it is resolved.
  public let rate: Double
  /// When true, a title with its own speed keeps it and the Focus speed replaces only the global
  /// default. Off by default: the Focus speed applies to everything.
  public let skipsTitlesWithOwnSpeed: Bool

  /// `skipsTitlesWithOwnSpeed` is optional because the filter's parameter is: an unset switch
  /// means off.
  public init(rate: Double, skipsTitlesWithOwnSpeed: Bool? = nil) {
    self.rate = rate
    self.skipsTitlesWithOwnSpeed = skipsTitlesWithOwnSpeed ?? false
  }
}

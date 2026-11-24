import AdSkip
import Foundation
import PlayerCore

/// How much silence Trim Silences removes.
public enum TrimStrength: String, Sendable, CaseIterable {
  /// Pauses of 0.30 s or more at -40 dB, each left with 0.15 s.
  case moderate
  /// Pauses of 0.105 s or more at -46 dB, removed up to `PauseTrimPlanner.leadIn`.
  case maximum

  var minimum: Double {
    switch self {
    case .moderate: 0.30
    case .maximum: 0.105
    }
  }

  var keep: Double {
    switch self {
    case .moderate: 0.15
    case .maximum: 0
    }
  }
}

/// Turns detected pause runs into the cuts of a `PlayerTrimMap`. Pure.
public enum PauseTrimPlanner {
  /// Cuts shorter than this, measured after `keep` is applied and edges are quantised, are not
  /// worth a splice.
  static let minimumCut = 0.02
  /// Absorbs floating-point error in the duration comparisons, so 30 frames of 10 ms still count
  /// as 0.30 s.
  static let epsilon = 1e-6
  /// A run ending within this of the audio's end reaches it (half a 10 ms frame).
  static let endTolerance = 0.005
  /// Pause left before the speech after every cut: two MP3 frames and change. On an iPhone each
  /// kept segment of a trimmed MP3 starts up to two frames (52 ms) late, so a cut that ran to the
  /// speech would clip its first sound.
  static let leadIn = 0.06

  public static func map(for runs: PauseRuns, strength: TrimStrength) -> PlayerTrimMap {
    let source = strength == .moderate ? runs.runsBelow40 : runs.runsBelow46
    return PlayerTrimMap(
      cuts: cuts(
        from: source, duration: runs.duration, minimum: strength.minimum, keep: strength.keep))
  }

  /// A run `[a, b]` at least `minimum` long becomes
  /// `[a + keep/2, b - max(keep/2, leadIn)]`. A run that reaches the end of the audio is not cut,
  /// so the composition always ends where the file does.
  static func cuts(
    from runs: [PauseRun], duration: Double, minimum: Double, keep: Double,
    leadIn: Double = PauseTrimPlanner.leadIn
  ) -> [PlayerTrimMap.Cut] {
    let scale = Double(PlayerTrimMap.timescale)
    func quantised(_ seconds: Double) -> Double { (seconds * scale).rounded() / scale }
    var result: [PlayerTrimMap.Cut] = []
    for run in runs {
      guard run.end - run.start >= minimum - epsilon else { continue }
      guard run.end < duration - endTolerance else { continue }
      let start = quantised(run.start + keep / 2)
      let end = quantised(run.end - max(keep / 2, leadIn))
      guard end - start >= minimumCut - epsilon else { continue }
      result.append(PlayerTrimMap.Cut(start: start, end: end))
    }
    return result
  }
}

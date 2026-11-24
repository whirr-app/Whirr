import AdSkip
import Foundation
import Persistence
import PlayerCore

/// The app-wide Trim Silences setting: the default for every show without its own setting.
/// `focus` is a Focus filter's trim while that Focus is on; it travels in this value so every
/// reader of the default hears a Focus change on the stream it already observes.
public struct TrimSilencesDefault: Sendable, Equatable {
  public var isEnabled: Bool
  public var strength: TrimStrength
  public var focus: FocusTrim?

  public init(isEnabled: Bool, strength: TrimStrength, focus: FocusTrim? = nil) {
    self.isEnabled = isEnabled
    self.strength = strength
    self.focus = focus
  }

  public static let off = TrimSilencesDefault(isEnabled: false, strength: .moderate)

  /// The setting as stored, without any Focus: what Settings and Show Settings name, and what
  /// `inherit` will mean once the Focus ends.
  public var stored: TrimSilencesDefault {
    TrimSilencesDefault(isEnabled: isEnabled, strength: strength)
  }
}

/// A Focus filter's trim. Device-local and never persisted by Core: the App holds it.
public struct FocusTrim: Sendable, Equatable {
  /// Nil trims nothing.
  public var strength: TrimStrength?
  /// Shows with their own setting keep it, as Keep Custom Speeds does for speed.
  public var keepsShowSettings: Bool

  public init(strength: TrimStrength?, keepsShowSettings: Bool) {
    self.strength = strength
    self.keepsShowSettings = keepsShowSettings
  }
}

/// What a show actually plays with, from the default and the show's own setting. Pure.
public enum TrimSilencesResolution {
  /// Nil means the show plays untrimmed.
  public static func strength(
    default value: TrimSilencesDefault, showOverride: TrimSilencesShowOverride
  ) -> TrimStrength? {
    if let focus = value.focus, focusGoverns(default: value, showOverride: showOverride) {
      return focus.strength
    }
    switch showOverride {
    case .inherit: return value.isEnabled ? value.strength : nil
    case .off: return nil
    case .moderate: return .moderate
    case .maximum: return .maximum
    }
  }

  /// Whether a Focus decides this show's trim rather than its own setting or the stored default.
  public static func focusGoverns(
    default value: TrimSilencesDefault, showOverride: TrimSilencesShowOverride
  ) -> Bool {
    guard let focus = value.focus else { return false }
    return focus.keepsShowSettings == false || showOverride == .inherit
  }

  /// The override a tap on the speed card's row should write for a show: the default
  /// strength when ticked, `off` when unticked, and `inherit` whenever that is what the show would
  /// resolve to anyway, so a show is not pinned by accident. Under a Focus, `inherit` must match
  /// both now and once the Focus ends, or the tap would be lost when it does.
  public static func overrideForToggle(
    toOn isOn: Bool, default value: TrimSilencesDefault
  ) -> TrimSilencesShowOverride {
    let stored = value.stored
    let wanted: TrimSilencesShowOverride =
      isOn ? (stored.strength == .moderate ? .moderate : .maximum) : .off
    let inheritMatches = [value, stored].allSatisfy { basis in
      strength(default: basis, showOverride: wanted)
        == strength(default: basis, showOverride: .inherit)
    }
    return inheritMatches ? .inherit : wanted
  }

  /// The speed card's tap for a show currently set to `current`. A Focus that decides every show
  /// keeps deciding whatever is written, so the tap flips the stored setting instead, which takes
  /// effect when the Focus ends.
  public static func toggledOverride(
    from current: TrimSilencesShowOverride, default value: TrimSilencesDefault
  ) -> TrimSilencesShowOverride {
    let decidesEveryShow = value.focus.map { $0.keepsShowSettings == false } ?? false
    let basis = decidesEveryShow ? value.stored : value
    return overrideForToggle(
      toOn: strength(default: basis, showOverride: current) == nil, default: value)
  }
}

/// Where the app-wide Trim Silences setting comes from. The App reads it from `UserDefaults`.
public protocol TrimSilencesDefaultSource: Sendable {
  /// Read synchronously at each load, so the first load after launch never waits for a stream.
  var current: TrimSilencesDefault { get }
  /// Emits whenever the setting changes. It may also emit the current value first.
  func observeDefault() -> AsyncStream<TrimSilencesDefault>
}

/// What the analysis store says about the loaded file.
public enum PlaybackTrimAnswer: Sendable, Equatable {
  case runs(PauseRuns, timing: PlaybackTrimTiming)
  /// Not analysed yet, or analysed for an older file or detector.
  case notAnalysed
  case unavailable(PlaybackTrimUnavailability)
  /// A stream, a multi-file item or an audiobook.
  case notApplicable
}

/// How the trimmed composition must read the file.
public enum PlaybackTrimTiming: Sendable, Equatable {
  /// The file's estimated timeline matches the decode, so the cheap imprecise asset will do.
  case estimated
  /// The estimate drifts, so the composition is built from an asset that scans the file for exact
  /// timing.
  case precise
}

public enum PlaybackTrimUnavailability: Sendable, Equatable {
  /// The file could not be analysed.
  case unreadable
}

/// Where `PlaybackModel` gets the loaded file's pause analysis. `PauseTrimCoordinator` is the
/// production source. Asking also puts the episode first in the analysis queue.
public protocol PlaybackTrimSource: Sendable {
  func trimAnswer(for request: PlaybackSkipRangeRequest) async -> PlaybackTrimAnswer
  /// Yields whenever a stored analysis may have changed.
  func trimChanges() -> AsyncStream<Void>
}

/// Builds what the engine plays for a trimmed file, before PlayerCore hears of the map.
/// True means the engine holds a prepared composition for exactly this file and map.
public protocol PlaybackTrimPreparing: Sendable {
  func prepare(map: PlayerTrimMap, forFileURL url: URL, timing: PlaybackTrimTiming) async -> Bool
}

/// One file's pause analysis.
public struct PauseAnalysis: Sendable, Equatable {
  public var runs: PauseRuns
  /// Whether the player's timeline for the file matches the decode. A misaligned file is
  /// trimmed through a precise-timing composition.
  public var isAligned: Bool

  public init(runs: PauseRuns, isAligned: Bool) {
    self.runs = runs
    self.isAligned = isAligned
  }
}

/// Decodes a downloaded file and finds its pauses. The App adapter is `AudioFilePauseAnalyser`.
public protocol PauseAnalysing: Sendable {
  func analyse(fileAt url: URL) async throws -> PauseAnalysis
}

/// What the speed card says about Trim Silences for the loaded episode.
public enum PlaybackTrimStatus: Sendable, Equatable {
  /// The loaded show resolves to off, or nothing is loaded.
  case off
  /// A stream, a multi-file item or an audiobook.
  case notApplicable
  /// Waiting for the episode's analysis or for its composition.
  case preparing
  /// The file cannot be trimmed.
  case unavailable
  case trimming(savedThisEpisode: Double)
}

/// The trim ports `PlaybackModel` takes, together.
public struct PlaybackTrimDependencies: Sendable {
  public var source: any PlaybackTrimSource
  public var preparer: any PlaybackTrimPreparing
  public var defaults: any TrimSilencesDefaultSource
  public var showSettings: any TrimSilencesShowSettingsReading
  /// How long a load waits for the map before it goes ahead untrimmed.
  public var preparationBudget: Duration

  public init(
    source: any PlaybackTrimSource, preparer: any PlaybackTrimPreparing,
    defaults: any TrimSilencesDefaultSource, showSettings: any TrimSilencesShowSettingsReading,
    preparationBudget: Duration = .milliseconds(300)
  ) {
    self.source = source
    self.preparer = preparer
    self.defaults = defaults
    self.showSettings = showSettings
    self.preparationBudget = preparationBudget
  }
}

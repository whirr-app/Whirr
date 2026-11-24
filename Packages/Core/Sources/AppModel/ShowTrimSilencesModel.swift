import Foundation
import Observation
import Persistence

/// One show's Trim Silences setting, for the picker on its settings page and the tick row on the
/// speed card. Both write the same override; the card's row goes through `toggle()`.
@MainActor
@Observable
public final class ShowTrimSilencesModel {
  public let itemID: String
  public private(set) var showOverride: TrimSilencesShowOverride = .inherit
  public private(set) var defaultValue: TrimSilencesDefault

  /// Default first, in the speed picker's inherit-first shape.
  public let choices: [TrimSilencesShowOverride] = [.inherit, .off, .moderate, .maximum]

  /// The strength the show plays with; nil plays it untrimmed.
  public var resolvedStrength: TrimStrength? {
    TrimSilencesResolution.strength(default: defaultValue, showOverride: showOverride)
  }

  public var isOn: Bool { resolvedStrength != nil }

  private let settings: any (TrimSilencesShowSettingsReading & TrimSilencesShowSettingsWriting)
  private let defaults: any TrimSilencesDefaultSource
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []

  public init(
    itemID: String,
    settings: any (TrimSilencesShowSettingsReading & TrimSilencesShowSettingsWriting),
    defaults: any TrimSilencesDefaultSource
  ) {
    self.itemID = itemID
    self.settings = settings
    self.defaults = defaults
    defaultValue = defaults.current
    observe()
  }

  deinit {
    for task in tasks { task.cancel() }
  }

  public func label(for choice: TrimSilencesShowOverride) -> String {
    TrimSilencesCopy.showChoiceLabel(choice, default: defaultValue)
  }

  public func setOverride(_ value: TrimSilencesShowOverride) async {
    let previous = showOverride
    showOverride = value
    do {
      try await settings.setTrimSilencesOverride(itemID: itemID, override: value)
    } catch {
      // The stream is the truth; a failed write puts back what is stored.
      showOverride = previous
    }
  }

  /// Whether a Focus decides this show's trim right now, for the speed card's footer.
  public var isGovernedByFocus: Bool {
    TrimSilencesResolution.focusGoverns(default: defaultValue, showOverride: showOverride)
  }

  /// The speed card's tick row: on writes the default strength, off writes `off`, and either
  /// clears the override when it matches what the show would inherit.
  public func toggle() async {
    await setOverride(
      TrimSilencesResolution.toggledOverride(from: showOverride, default: defaultValue))
  }

  private func observe() {
    let overrides = settings.observeTrimSilencesOverrides()
    let defaultChanges = defaults.observeDefault()
    let itemID = itemID
    tasks = [
      Task { [weak self] in
        for await values in overrides {
          guard let self else { return }
          let next = values[itemID] ?? .inherit
          if self.showOverride != next { self.showOverride = next }
        }
      },
      Task { [weak self] in
        for await value in defaultChanges {
          guard let self else { return }
          if self.defaultValue != value { self.defaultValue = value }
        }
      },
    ]
  }
}

/// Trim Silences' copy, shared by Settings, the show settings page and the speed card.
public enum TrimSilencesCopy {
  public static let title = "Trim Silences"
  public static let strengthTitle = "Strength"
  public static let symbol = "scissors"
  public static let settingsFooter =
    "Shortens pauses in downloaded podcast episodes. Shows can have their own setting."

  /// Display names only: the stored values stay `moderate` and `maximum`, so nothing migrates.
  public static func strengthLabel(_ strength: TrimStrength) -> String {
    switch strength {
    case .moderate: "Low"
    case .maximum: "High"
    }
  }

  /// "Default (Low)", "Default (High)" or "Default (Off)" for `inherit`. Always the stored
  /// default, never a Focus's, as this picker changes the stored setting.
  public static func showChoiceLabel(
    _ choice: TrimSilencesShowOverride, default value: TrimSilencesDefault
  ) -> String {
    switch choice {
    case .inherit:
      "Default (\(TrimSilencesResolution.strength(default: value.stored, showOverride: .inherit).map(strengthLabel) ?? "Off"))"
    case .off: "Off"
    case .moderate: strengthLabel(.moderate)
    case .maximum: strengthLabel(.maximum)
    }
  }

  /// The line under the speed card's row. Nil when the show plays untrimmed.
  public static func caption(for status: PlaybackTrimStatus) -> String? {
    switch status {
    case .off: nil
    case .notApplicable: "Only downloaded episodes are trimmed."
    case .preparing: "Getting this episode ready…"
    case .unavailable: "This episode can't be trimmed."
    case .trimming(let saved): "Saved \(clock(saved)) in this episode."
    }
  }

  /// Added to the speed card's caption while a Focus decides the show's trim. Short, so the
  /// longest status plus this still fits the caption's two lines.
  public static let focusCaption = "Your Focus decides until it ends."

  /// The whole line under the speed card's row: the episode's status while the show is trimmed,
  /// then the Focus sentence while a Focus decides it. Nil when there is nothing to say.
  public static func cardCaption(
    status: PlaybackTrimStatus, isOn: Bool, isGovernedByFocus: Bool
  ) -> String? {
    let parts = [isOn ? caption(for: status) : nil, isGovernedByFocus ? focusCaption : nil]
      .compactMap(\.self)
    return parts.isEmpty ? nil : parts.joined(separator: " ")
  }

  /// m:ss, or h:mm:ss from an hour.
  static func clock(_ seconds: Double) -> String {
    let total = seconds.isFinite ? max(Int(seconds), 0) : 0
    let (hours, minutes, secs) = (total / 3_600, total / 60 % 60, total % 60)
    let tail = String(format: "%02d", secs)
    return hours > 0
      ? "\(hours):\(String(format: "%02d", minutes)):\(tail)" : "\(minutes):\(tail)"
  }
}

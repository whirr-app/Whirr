import Foundation
import Observation
import Persistence

/// What a show plays with, from the app-wide Voice Boost setting and the show's own.
/// Pure.
public enum VoiceBoostResolution {
  public static func isOn(default isEnabled: Bool, showOverride: VoiceBoostShowOverride) -> Bool {
    switch showOverride {
    case .inherit: isEnabled
    case .on: true
    case .off: false
    }
  }

  /// The override a tap on the speed card's row writes for a show: `on` or `off`, or
  /// `inherit` when that is what the show would resolve to anyway.
  public static func overrideForToggle(
    toOn isOn: Bool, default isEnabled: Bool
  ) -> VoiceBoostShowOverride {
    isOn == isEnabled ? .inherit : (isOn ? .on : .off)
  }
}

/// Where the app-wide Voice Boost setting comes from. The App reads it from `UserDefaults`.
public protocol VoiceBoostDefaultSource: Sendable {
  var current: Bool { get }
  /// Emits whenever the setting changes. It may also emit the current value first.
  func observeDefault() -> AsyncStream<Bool>
}

/// One show's Voice Boost setting, for the picker on its settings page and the tick row
/// on the speed card, in the shape of `ShowTrimSilencesModel`.
@MainActor
@Observable
public final class ShowVoiceBoostModel {
  public let itemID: String
  public private(set) var showOverride: VoiceBoostShowOverride = .inherit
  public private(set) var defaultValue: Bool

  public let choices: [VoiceBoostShowOverride] = [.inherit, .on, .off]

  public var isOn: Bool {
    VoiceBoostResolution.isOn(default: defaultValue, showOverride: showOverride)
  }

  private let settings: any (VoiceBoostShowSettingsReading & VoiceBoostShowSettingsWriting)
  private let defaults: any VoiceBoostDefaultSource
  @ObservationIgnored private var tasks: [Task<Void, Never>] = []

  public init(
    itemID: String,
    settings: any (VoiceBoostShowSettingsReading & VoiceBoostShowSettingsWriting),
    defaults: any VoiceBoostDefaultSource
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

  public func label(for choice: VoiceBoostShowOverride) -> String {
    VoiceBoostShowCopy.showChoiceLabel(choice, default: defaultValue)
  }

  public func setOverride(_ value: VoiceBoostShowOverride) async {
    let previous = showOverride
    showOverride = value
    do {
      try await settings.setVoiceBoostOverride(itemID: itemID, override: value)
    } catch {
      showOverride = previous
    }
  }

  public func toggle() async {
    await setOverride(VoiceBoostResolution.overrideForToggle(toOn: isOn == false, default: defaultValue))
  }

  private func observe() {
    let overrides = settings.observeVoiceBoostOverrides()
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

/// The show settings picker's labels. The rest of Voice Boost's copy is the App's `VoiceBoostCopy`.
public enum VoiceBoostShowCopy {
  /// "Default (On)" or "Default (Off)" for `inherit`.
  public static func showChoiceLabel(
    _ choice: VoiceBoostShowOverride, default isEnabled: Bool
  ) -> String {
    switch choice {
    case .inherit: isEnabled ? "Default (On)" : "Default (Off)"
    case .on: "On"
    case .off: "Off"
    }
  }
}

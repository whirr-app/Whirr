import AppIntents
import AppModel
import Foundation
import PlayerCore

// Whirr's Focus filter. App-only: `SiriPlaybackIntents.swift` is also compiled into the widget
// extension, and an app may declare only one `SetFocusFilterIntent`.

/// The speeds a Focus may set: 0.5× to 2× in twentieths, the player's custom speed range, so the
/// Settings picker cannot offer a value the resolver would reject.
enum PlaybackSpeedOption: String, AppEnum, CaseIterable {
  case x050 = "0.50"
  case x055 = "0.55"
  case x060 = "0.60"
  case x065 = "0.65"
  case x070 = "0.70"
  case x075 = "0.75"
  case x080 = "0.80"
  case x085 = "0.85"
  case x090 = "0.90"
  case x095 = "0.95"
  case x100 = "1.00"
  case x105 = "1.05"
  case x110 = "1.10"
  case x115 = "1.15"
  case x120 = "1.20"
  case x125 = "1.25"
  case x130 = "1.30"
  case x135 = "1.35"
  case x140 = "1.40"
  case x145 = "1.45"
  case x150 = "1.50"
  case x155 = "1.55"
  case x160 = "1.60"
  case x165 = "1.65"
  case x170 = "1.70"
  case x175 = "1.75"
  case x180 = "1.80"
  case x185 = "1.85"
  case x190 = "1.90"
  case x195 = "1.95"
  case x200 = "2.00"

  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Playback Speed")
  // A literal: the App Intents metadata processor reads this table at build time.
  static let caseDisplayRepresentations: [PlaybackSpeedOption: DisplayRepresentation] = [
    .x050: "0.5×",
    .x055: "0.55×",
    .x060: "0.6×",
    .x065: "0.65×",
    .x070: "0.7×",
    .x075: "0.75×",
    .x080: "0.8×",
    .x085: "0.85×",
    .x090: "0.9×",
    .x095: "0.95×",
    .x100: "1×",
    .x105: "1.05×",
    .x110: "1.1×",
    .x115: "1.15×",
    .x120: "1.2×",
    .x125: "1.25×",
    .x130: "1.3×",
    .x135: "1.35×",
    .x140: "1.4×",
    .x145: "1.45×",
    .x150: "1.5×",
    .x155: "1.55×",
    .x160: "1.6×",
    .x165: "1.65×",
    .x170: "1.7×",
    .x175: "1.75×",
    .x180: "1.8×",
    .x185: "1.85×",
    .x190: "1.9×",
    .x195: "1.95×",
    .x200: "2×",
  ]

  /// Raw values are exact decimal strings, so this never fails for a declared case.
  var rate: Double { Double(rawValue) ?? PlaybackRateResolution.defaultRate }

  /// "0.9×", "1×", "1.25×": the same shape the player's speed menu uses.
  var label: String { PlaybackSpeedFocusFilterCopy.rateLabel(rate) }
}

/// The trims a Focus may set. User-facing Low and High are `TrimStrength.moderate` and `.maximum`.
enum FocusTrimOption: String, AppEnum, CaseIterable {
  case off
  case low
  case high

  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Trim Silences")
  // A literal: the App Intents metadata processor reads this table at build time.
  static let caseDisplayRepresentations: [FocusTrimOption: DisplayRepresentation] = [
    .off: "Off",
    .low: "Low",
    .high: "High",
  ]

  /// Nil trims nothing.
  var strength: TrimStrength? {
    switch self {
    case .off: nil
    case .low: .moderate
    case .high: .maximum
    }
  }
}

/// The sleep timers a Focus may start. Timed only: an end-of-chapter timer needs chapters the
/// Focus cannot know about when it is set up.
enum FocusSleepTimerOption: String, AppEnum, CaseIterable {
  case m5 = "5"
  case m10 = "10"
  case m15 = "15"
  case m20 = "20"
  case m25 = "25"
  case m30 = "30"
  case m45 = "45"
  case m60 = "60"
  case m90 = "90"
  case m120 = "120"

  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Sleep Timer")
  // A literal: the App Intents metadata processor reads this table at build time.
  static let caseDisplayRepresentations: [FocusSleepTimerOption: DisplayRepresentation] = [
    .m5: "5 minutes",
    .m10: "10 minutes",
    .m15: "15 minutes",
    .m20: "20 minutes",
    .m25: "25 minutes",
    .m30: "30 minutes",
    .m45: "45 minutes",
    .m60: "1 hour",
    .m90: "1.5 hours",
    .m120: "2 hours",
  ]

  /// Raw values are whole minutes, so this never fails for a declared case.
  var minutes: Int { Int(rawValue) ?? 0 }
  var seconds: Double { Double(minutes * 60) }
}

/// Keeps its speed-only name because renaming a `SetFocusFilterIntent` type risks breaking Focus
/// filters already set up. The filter covers speed, trim and a sleep timer, nothing else.
struct PlaybackSpeedFocusFilter: SetFocusFilterIntent {
  static let title: LocalizedStringResource = "Set Playback Options"
  static let description = IntentDescription(
    "Change the playback speed and Trim Silences, and start a sleep timer each time you play, while this Focus is on."
  )

  // All optional: deactivation arrives as all `nil`, and non-optional parameters reportedly stop
  // that call arriving.
  @Parameter(title: "Speed") var speed: PlaybackSpeedOption?
  // The stored key stays `skipsTitlesWithOwnSpeed`, so filters already set up keep their value.
  @Parameter(
    title: "Keep Custom Speeds",
    description: "Books and podcasts you've set your own speed for keep it.")
  var skipsTitlesWithOwnSpeed: Bool?
  @Parameter(title: "Trim Silences") var trimSilences: FocusTrimOption?
  @Parameter(
    title: "Keep Custom Trim",
    description: "Shows you've set your own Trim Silences for keep it.")
  var keepsCustomTrim: Bool?
  @Parameter(
    title: "Sleep Timer",
    description: "Starts a sleep timer each time you play, unless one is already running.")
  var sleepTimer: FocusSleepTimerOption?

  var displayRepresentation: DisplayRepresentation {
    let summary = PlaybackSpeedFocusFilterCopy.summary(
      rate: speed?.rate, skipsTitlesWithOwnSpeed: skipsTitlesWithOwnSpeed,
      trim: trimSilences, keepsCustomTrim: keepsCustomTrim, sleepTimer: sleepTimer)
    return DisplayRepresentation(title: "\(summary)")
  }

  /// What this delivery means for playback: no speed is no Focus speed.
  var focusSpeed: FocusSpeed? {
    speed.map { FocusSpeed(rate: $0.rate, skipsTitlesWithOwnSpeed: skipsTitlesWithOwnSpeed) }
  }

  /// No trim leaves trimming alone; an unset Keep Custom Trim means off.
  var focusTrim: FocusTrim? {
    trimSilences.map { FocusTrim(strength: $0.strength, keepsShowSettings: keepsCustomTrim == true) }
  }

  var focusValue: FocusFilterValue {
    FocusFilterValue(speed: focusSpeed, trim: focusTrim, sleepTimerSeconds: sleepTimer?.seconds)
  }

  /// Nonisolated in this MainActor-default target, so the hop is explicit. Composes nothing: iOS
  /// may call this before first unlock or with no scene, so it only records the value and tells
  /// whatever coordinator the running app already has.
  func perform() async throws -> some IntentResult {
    let focusValue = focusValue
    await MainActor.run { FocusPlaybackSpeedState.shared.deliver(focusValue) }
    return .result()
  }
}

nonisolated enum PlaybackSpeedFocusFilterCopy {
  static func rateLabel(_ rate: Double) -> String {
    PlaybackRatePresetConfiguration.display(rate)
  }

  /// The filter's summary in Settings › Focus: "0.9× · Trim off",
  /// "0.9× · Keeps custom speeds · Trim low · Sleep timer 30 min".
  static func summary(
    rate: Double?, skipsTitlesWithOwnSpeed: Bool?, trim: FocusTrimOption? = nil,
    keepsCustomTrim: Bool? = nil, sleepTimer: FocusSleepTimerOption? = nil
  ) -> String {
    var parts: [String] = []
    if let rate {
      parts.append(rateLabel(rate))
      if skipsTitlesWithOwnSpeed == true { parts.append("Keeps custom speeds") }
    }
    if let trim {
      parts.append("Trim \(trimLabel(trim))")
      if keepsCustomTrim == true { parts.append("Keeps custom trim") }
    }
    if let sleepTimer { parts.append("Sleep timer \(sleepTimer.minutes) min") }
    return parts.isEmpty ? "No changes" : parts.joined(separator: " · ")
  }

  static func trimLabel(_ trim: FocusTrimOption) -> String {
    trim.strength.map { TrimSilencesCopy.strengthLabel($0).lowercased() } ?? "off"
  }
}

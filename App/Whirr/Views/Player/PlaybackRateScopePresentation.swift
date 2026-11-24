import Foundation

/// Copy for the speed controls: the player's speed card, its custom speed alert, and the two
/// Settings rows for speeds the card doesn't hold (a show's own and the app-wide default). Free of
/// SwiftUI types so the wording, the feature's whole discoverability, is unit-testable. The player
/// only pins the playing title; the default is set in Settings → Playback alone, so no player
/// control has to say which of two numbers it changes.
nonisolated enum PlaybackRateScopePresentation {
  /// Which media a speed control is being drawn for. Podcast episodes carry an episode id and
  /// resolve against their show, so the player's own `episodeID` is the only signal needed.
  enum Kind: Sendable, Equatable {
    case book
    case show

    static func resolve(episodeID: String?) -> Self {
      episodeID == nil ? .book : .show
    }
  }

  /// The card's header. The presets always pin this one title, so the header states that rather
  /// than reporting which of two numbers the next tap lands on. `focusRate` is the rate a Focus is
  /// playing this title at, or nil when none governs it.
  static func menuHeader(kind: Kind, focusRate: Double? = nil) -> String {
    if focusRate != nil { return "Speed Set by Focus" }
    return kind == .book ? "Speed for This Book" : "Speed for This Show"
  }

  /// Show Settings' inherit-first menu, in the same shape as the three override rows it sits
  /// beside: `nil` (inherit) first, then the listener's own speed shortcuts, then the show's
  /// current value when that value is not one of them. Without that last entry a show set to
  /// 1.35× from the player would silently read as inheriting.
  static func showSpeedChoices(encodedPresets: String, currentRate: Double?) -> [Double?] {
    var choices: [Double?] = [nil]
    let presets = PlaybackRatePresetConfiguration.decode(encodedPresets).rates
    choices.append(contentsOf: presets.map { Optional($0) })
    if let currentRate, presets.contains(where: { abs($0 - currentRate) < 0.001 }) == false {
      choices.append(currentRate)
    }
    return choices
  }

  static func showSpeedLabel(_ choice: Double?, defaultRate: Double) -> String {
    guard let choice else {
      return "Default (\(PlaybackRatePresetConfiguration.display(defaultRate)))"
    }
    return PlaybackRatePresetConfiguration.display(choice)
  }

  /// Settings → Playback's default-speed choices: the listener's own shortcuts, plus the current
  /// default when it is not one of them, else a default stored at 1.35× (or whose shortcut was
  /// deleted) would have no row and the picker would read as unset.
  ///
  /// Unlike `showSpeedChoices` there is no inherit entry: the default is what is inherited from.
  static func defaultSpeedChoices(encodedPresets: String, currentRate: Double) -> [Double] {
    var choices = PlaybackRatePresetConfiguration.decode(encodedPresets).rates
    if choices.contains(where: { abs($0 - currentRate) < 0.001 }) == false {
      choices.append(currentRate)
    }
    return choices
  }

  static let showSpeedRowTitle = "Playback Speed"

  static let defaultSpeedRowTitle = "Default Speed"
  /// Names what the default is for, the half of the model the player cannot teach because its
  /// presets only pin one title. One line at body width, like every other footer on this screen:
  /// a settings list that explains itself in paragraphs reads as a manual. The Focus sentence
  /// extends this footer rather than adding a second one.
  static let defaultSpeedFooter =
    "Used by titles without their own speed. A Focus filter can change the speed while that Focus is on."

  static let useDefaultTitle = "Use Default Speed"
  /// Opens the custom speed alert. A number field, not a slider: the presets cover the coarse
  /// choices, and what is left is an exact value.
  static let customSpeedTitle = "Custom Speed…"
  static let customSpeedSymbol = "number"
  static let customSpeedAlertTitle = "Custom Speed"
  static let customSpeedFieldPrompt = "Speed"
  static let customSpeedSetTitle = "Set"
  static var customSpeedMessage: String {
    let range = PlaybackRatePresetConfiguration.customSpeedRange
    return
      "Enter a speed from \(PlaybackRatePresetConfiguration.display(range.lowerBound)) to \(PlaybackRatePresetConfiguration.display(range.upperBound))."
  }
}

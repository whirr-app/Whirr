/// One table for why ad analysis waits. The settings row, the episode card and the player each
/// render the same three reasons, so a new reason or a changed sentence is one edit here.
nonisolated enum AdSkipWaitPresentation {
  struct CardCopy: Equatable {
    /// Shown when it fits beside the heading, and always what VoiceOver reads.
    let full: String
    /// Shown when the full copy does not fit.
    let short: String
    let systemImage: String
  }

  struct PlayerCopy: Equatable {
    let text: String
    let systemImage: String
    /// Only the charging wait can be lifted from the player.
    let offersCheckNow: Bool
  }

  /// The settings row's detail line under the progress bar.
  static func settingsDetail(_ reason: AdSkipPauseReason) -> String {
    switch reason {
    case .notCharging: "Waiting for iPhone to charge"
    case .lowPowerMode: "Paused in Low Power Mode"
    case .warm: "Paused while iPhone is warm"
    }
  }

  /// The episode card's short row beside "Show notes".
  static func card(_ reason: AdSkipPauseReason) -> CardCopy {
    switch reason {
    case .notCharging:
      CardCopy(full: "Checks for ads when charging", short: "When charging", systemImage: "bolt")
    case .lowPowerMode:
      CardCopy(
        full: "Ad check paused in Low Power Mode", short: "Paused", systemImage: "battery.25")
    case .warm:
      CardCopy(
        full: "Ad check paused while phone cools", short: "Paused",
        systemImage: "thermometer.medium")
    }
  }

  /// The expanded player's one plain sentence.
  static func player(_ reason: AdSkipPauseReason) -> PlayerCopy {
    switch reason {
    case .notCharging:
      PlayerCopy(
        text: "Ads will be checked when your phone is charging", systemImage: "bolt",
        offersCheckNow: true)
    case .lowPowerMode:
      PlayerCopy(
        text: "Ad checks are paused in Low Power Mode", systemImage: "battery.25",
        offersCheckNow: false)
    case .warm:
      PlayerCopy(
        text: "Ad checks are paused while your phone cools down", systemImage: "thermometer.medium",
        offersCheckNow: false)
    }
  }
}

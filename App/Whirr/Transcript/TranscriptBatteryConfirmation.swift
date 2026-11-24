import UIKit

/// The question asked before transcribing on battery, and the setting that stops it being asked.
enum TranscriptBatteryConfirmation {
  static let skipKey = "transcript.skipsBatteryConfirmation"
  static let title = "Transcribe on Battery?"
  static let message =
    "Whirr transcribes on this iPhone. It takes a few minutes for an hour of audio, uses battery, and can make the iPhone warm."
  static let transcribe = "Transcribe"
  static let transcribeAndStopAsking = "Transcribe and Don’t Ask Again"

  /// `.unknown` (no reading) counts as battery, so the question errs towards being asked.
  @MainActor
  static func isOnExternalPower() -> Bool {
    let device = UIDevice.current
    device.isBatteryMonitoringEnabled = true
    return device.batteryState == .charging || device.batteryState == .full
  }
}

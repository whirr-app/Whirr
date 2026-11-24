import SwiftUI
import UIKit

/// A paragraph's start, as a quiet control that plays from there.
struct TranscriptTimestampButton: View {
  let start: Double
  /// Look Back's playhead: the time is then drawn counting back from it, as "−12:30".
  var countingBackFrom: Double? = nil
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(
        countingBackFrom.map { TranscriptTimestamp.text(before: $0, start: start) } ?? TranscriptTimestamp.text(start)
      )
      .font(.caption.monospacedDigit().weight(.medium))
      // Concrete, not `.secondary`: over the half detent's glass a hierarchical style is drawn
      // vibrant, so the timestamps changed weight as the sheet grew opaque.
      .foregroundStyle(Color(uiColor: .secondaryLabel))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
  }

  private var accessibilityLabel: String {
    guard let playhead = countingBackFrom else {
      return "Play from \(Duration.seconds(max(0, start.rounded(.down))).formatted(.units(width: .wide)))"
    }
    let back = Duration.seconds(TranscriptTimestamp.secondsBefore(playhead, start: start))
    return "Play from \(back.formatted(.units(width: .wide))) back"
  }
}

/// Clock text for a transcript position: minutes and seconds, with hours once there are any.
enum TranscriptTimestamp {
  static func text(_ seconds: Double) -> String {
    let total = Int(max(0, seconds.rounded(.down)))
    let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
    let twoDigits = { (value: Int) in value < 10 ? "0\(value)" : "\(value)" }
    return hours > 0
      ? "\(hours):\(twoDigits(minutes)):\(twoDigits(secs))" : "\(minutes):\(twoDigits(secs))"
  }

  /// How far `start` is before `playhead`, in whole seconds, rounded up so a sentence never reads
  /// as nearer than it is.
  static func secondsBefore(_ playhead: Double, start: Double) -> Int {
    Int(max(0, playhead - start).rounded(.up))
  }

  /// `start` counted back from `playhead`, with a true minus sign: "−12:30".
  static func text(before playhead: Double, start: Double) -> String {
    "\u{2212}" + text(Double(secondsBefore(playhead, start: start)))
  }
}

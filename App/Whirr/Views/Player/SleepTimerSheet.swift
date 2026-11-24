import PlayerCore
import SwiftUI
import UIKit

/// The Custom Timer's compact height: the medium half where that holds the form, otherwise as
/// much of the form as the window has. A short window (an iPhone Duo panel, open or closed) halves
/// to well under the form, and a plain `.medium` clipped the wheel there.
nonisolated struct SleepTimerSheetDetent: CustomPresentationDetent {
  /// The form at the default text size: the bar, the segmented picker, the 216-point wheel and
  /// the summary footer. Larger text still scrolls, and `.large` stays a drag away.
  static let requiredHeight: CGFloat = 470

  static func height(maxDetentValue: CGFloat) -> CGFloat {
    let available = max(maxDetentValue, 0)
    return min(available, max(available / 2, requiredHeight))
  }

  static func height(in context: Context) -> CGFloat? {
    height(maxDetentValue: context.maxDetentValue)
  }
}

/// Native data-entry for a one-off timer. Presets and timer cancellation live in the player menu;
/// persistent shortcut configuration lives in Settings.
struct SleepTimerSheet: View {
  private enum Mode: String, CaseIterable {
    case duration = "Duration"
    case clockTime = "Clock Time"
  }

  let onSet: (SleepTimerDuration) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var mode = Mode.duration
  @State private var hours = 0
  @State private var minutes = 30
  @State private var stopTime = Date.now.addingTimeInterval(30 * 60)

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Picker("Timer Type", selection: $mode) {
            ForEach(Mode.allCases, id: \.self) { mode in
              Text(mode.rawValue).tag(mode)
            }
          }
          .pickerStyle(.segmented)
        }

        Section {
          switch mode {
          case .duration:
            durationPicker
          case .clockTime:
            clockTimePicker
          }
        } footer: {
          Text(timerSummary)
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Custom Timer")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(role: .close) {
            dismiss()
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Start") {
            onSet(.custom(seconds: secondsUntilStop))
            dismiss()
          }
          // The sheet sits over the artwork-driven player, so confirmation uses the page's neutral,
          // not system blue or Settings navy. The fill is semantic because the sheet takes the
          // polarity of the page beneath; a literal white would be a white capsule on a white Form.
          //
          // No `role: .confirm`: its prominent styling fills system blue and ignores this `tint`.
          // The label states its own colour, since a prominent button paints it white whatever the
          // tint; on a `.primary` fill that is the background `.primary` is defined against.
          .buttonStyle(.glassProminent)
          .buttonBorderShape(.capsule)
          .tint(.primary)
          .foregroundStyle(Color(uiColor: .systemBackground))
          .disabled(secondsUntilStop <= 0)
        }
      }
    }
  }

  private var durationPicker: some View {
    HStack(spacing: 0) {
      Picker("Hours", selection: $hours) {
        ForEach(0...8, id: \.self) { value in
          Text("\(value) hr").tag(value)
        }
      }
      Picker("Minutes", selection: $minutes) {
        ForEach(0...59, id: \.self) { value in
          Text("\(value) min").tag(value)
        }
      }
    }
    .pickerStyle(.wheel)
  }

  private var clockTimePicker: some View {
    DatePicker(
      "Stop Playback At",
      selection: $stopTime,
      displayedComponents: .hourAndMinute
    )
    .datePickerStyle(.wheel)
  }

  private var timerSummary: String {
    switch mode {
    case .duration:
      let totalMinutes = hours * 60 + minutes
      return "Playback will stop after \(totalMinutes) minute\(totalMinutes == 1 ? "" : "s")."
    case .clockTime:
      return "Playback will stop at \(stopTime.formatted(date: .omitted, time: .shortened))."
    }
  }

  private var secondsUntilStop: Double {
    switch mode {
    case .duration:
      return Double((hours * 60 + minutes) * 60)
    case .clockTime:
      let calendar = Calendar.current
      let components = calendar.dateComponents([.hour, .minute], from: stopTime)
      guard
        let nextStop = calendar.nextDate(
          after: Date.now,
          matching: components,
          matchingPolicy: .nextTime,
          direction: .forward
        )
      else { return 0 }
      return nextStop.timeIntervalSinceNow
    }
  }
}

import AppIntents
import SwiftUI
import WidgetKit

/// The choice made when adding the control. `.off` is offered on purpose: it makes a dedicated
/// "Cancel Sleep Timer" button for the Action button or Lock Screen.
struct SleepTimerControlConfiguration: ControlConfigurationIntent {
  static let title: LocalizedStringResource = "Sleep Timer"

  @Parameter(title: "Duration", default: .thirtyMinutes)
  var duration: SiriSleepTimerDuration

  func perform() async throws -> some IntentResult {
    .result()
  }
}

struct SleepTimerControl: ControlWidget {
  static let kind = "com.remoteconcern.whirr.control.sleepTimer"

  var body: some ControlWidgetConfiguration {
    AppIntentControlConfiguration(kind: Self.kind, provider: Provider()) { duration in
      ControlWidgetButton(action: StartSleepTimerIntent(duration: duration)) {
        Label(duration.controlTitle, systemImage: duration == .off ? "moon.zzz" : "moon.zzz.fill")
      }
    }
    .displayName("Sleep Timer")
    .description("Starts a sleep timer, or cancels the running one.")
  }
}

extension SleepTimerControl {
  /// The chosen duration is the whole value; the control reads no snapshot.
  struct Provider: AppIntentControlValueProvider {
    func previewValue(configuration: SleepTimerControlConfiguration) -> SiriSleepTimerDuration {
      configuration.duration
    }

    func currentValue(configuration: SleepTimerControlConfiguration) async throws -> SiriSleepTimerDuration {
      configuration.duration
    }
  }
}

extension SiriSleepTimerDuration {
  fileprivate var controlTitle: String {
    switch self {
    case .off: "Cancel Sleep Timer"
    case .fifteenMinutes: "Sleep 15 min"
    case .thirtyMinutes: "Sleep 30 min"
    case .fortyFiveMinutes: "Sleep 45 min"
    case .sixtyMinutes: "Sleep 60 min"
    case .endOfChapter: "Sleep: End of Chapter"
    }
  }
}

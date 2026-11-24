import AppIntents
import SwiftUI
import WidgetKit
import WidgetProtocol

struct SkipBackControl: ControlWidget {
  static let kind = "com.remoteconcern.whirr.control.skipBack"

  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: Self.kind, provider: Provider()) { seconds in
      ControlWidgetButton(action: SkipBackIntent()) {
        Label(
          WidgetControlPresentation.skipBackLabel(seconds: seconds),
          systemImage: WidgetControlPresentation.skipBackSymbolName(seconds: seconds))
      }
    }
    .displayName("Skip Back")
    .description("Skips back by the interval set in Whirr.")
  }
}

extension SkipBackControl {
  /// The value is the user's skip interval in seconds, always one the app offers.
  struct Provider: ControlValueProvider {
    let previewValue = WidgetControlPresentation.fallbackSkipBackSeconds

    func currentValue() async throws -> Int {
      WidgetControlPresentation.skipBackSeconds(WidgetSnapshotReader.production.read().snapshot)
    }
  }
}

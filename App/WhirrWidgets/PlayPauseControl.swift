import AppIntents
import SwiftUI
import WidgetKit
import WidgetProtocol

struct PlayPauseControl: ControlWidget {
  static let kind = "com.remoteconcern.whirr.control.playPause"

  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: Self.kind, provider: Provider()) { isPlaying in
      ControlWidgetToggle("Whirr", isOn: isPlaying, action: SetPlayingIntent()) { isOn in
        Label(
          WidgetControlPresentation.playPauseValueText(isPlaying: isOn),
          systemImage: WidgetControlPresentation.playPauseSymbolName(isPlaying: isOn))
      }
    }
    .displayName("Play or Pause")
    .description("Starts or pauses Whirr playback.")
  }
}

extension PlayPauseControl {
  struct Provider: ControlValueProvider {
    let previewValue = false

    func currentValue() async throws -> Bool {
      WidgetControlPresentation.isPlaying(WidgetSnapshotReader.production.read().snapshot)
    }
  }
}

import AVKit
import SwiftUI

/// Bridge for the system audio-route picker. Its fixed AirPlay artwork neither reports the active
/// route nor matches the quick-action row, so `QuickActionsControls` draws the symbol from
/// `AudioRoutePresentation` and this view supplies only the tap target.
struct AudioRoutePicker: UIViewRepresentable {
  /// Where audio is playing, spoken as the control's value; the label is a sibling's.
  let spokenRoute: String

  func makeUIView(context: Context) -> AVRoutePickerView {
    let picker = AVRoutePickerView()
    picker.prioritizesVideoDevices = false
    picker.tintColor = .clear
    picker.activeTintColor = .clear
    picker.backgroundColor = .clear
    picker.accessibilityLabel = "AirPlay"
    picker.accessibilityValue = spokenRoute
    picker.accessibilityHint = "Choose where audio plays."
    return picker
  }

  func updateUIView(_ picker: AVRoutePickerView, context: Context) {
    picker.tintColor = .clear
    picker.activeTintColor = .clear
    picker.accessibilityValue = spokenRoute
  }
}

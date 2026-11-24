import Foundation
import SwiftUI

/// Custom Speed…'s presentation state. The field's text is filled when the prompt opens, not
/// when the alert appears: an alert's text field takes its value as it is presented and does not
/// pick up a later write.
nonisolated struct CustomSpeedPrompt: Equatable, Sendable {
  var isPresented = false
  var text = ""

  mutating func open(currentRate: Double, locale: Locale = .current) {
    text = PlaybackRatePresetConfiguration.inputText(currentRate, locale: locale)
    isPresented = true
  }
}

extension View {
  /// One number field, Cancel and Set. The speed card it is raised from already names the title
  /// the speed pins, so the alert has nothing to ask but the number.
  func customSpeedAlert(
    _ prompt: Binding<CustomSpeedPrompt>, onSet: @escaping (Double) -> Void
  ) -> some View {
    alert(PlaybackRateScopePresentation.customSpeedAlertTitle, isPresented: prompt.isPresented) {
      TextField(PlaybackRateScopePresentation.customSpeedFieldPrompt, text: prompt.text)
        .keyboardType(.decimalPad)
      Button("Cancel", role: .cancel) {}
      Button(PlaybackRateScopePresentation.customSpeedSetTitle) {
        // Unparseable text leaves the speed as it was; anything numeric is rounded and clamped.
        guard let rate = PlaybackRatePresetConfiguration.customRate(fromInput: prompt.wrappedValue.text)
        else { return }
        onSet(rate)
      }
    } message: {
      Text(PlaybackRateScopePresentation.customSpeedMessage)
    }
  }
}

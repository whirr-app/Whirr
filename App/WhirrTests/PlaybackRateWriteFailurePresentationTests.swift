import Foundation
import Testing

@testable import Whirr

/// Speed save failures reach the listener through `PlaybackRateCoordinator.writeFailureMessage`,
/// shown by one alert at the app root.
@Suite("Playback rate write failure presentation")
struct PlaybackRateWriteFailurePresentationTests {
  @Test("only a non-empty failure message presents the alert")
  func onlyARealMessagePresents() {
    #expect(PlaybackRateWriteFailurePresentation.isAlertPresented(for: nil) == false)
    #expect(PlaybackRateWriteFailurePresentation.isAlertPresented(for: "") == false)
    #expect(
      PlaybackRateWriteFailurePresentation.isAlertPresented(
        for: "Couldn't save that playback speed. Try again."))
  }
}

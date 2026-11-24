import Testing

@testable import Whirr

@Suite("Skip interval configuration")
struct SkipIntervalConfigurationTests {

  @Test("unset or unsupported storage resolves to the directional defaults")
  func unsupportedStorageUsesDirectionalDefault() {
    #expect(SkipIntervalConfiguration.resolvedSeconds(0, forward: true) == 30)
    #expect(SkipIntervalConfiguration.resolvedSeconds(0, forward: false) == 15)
    #expect(SkipIntervalConfiguration.resolvedSeconds(-5, forward: true) == 30)
    #expect(SkipIntervalConfiguration.resolvedSeconds(7, forward: false) == 15)
    #expect(SkipIntervalConfiguration.resolvedSeconds(90, forward: true) == 90)
  }

  @Test("button glyph carries each configured directional interval")
  func systemImageUsesNumberedGlyph() {
    #expect(SkipIntervalConfiguration.systemImage(seconds: 15, forward: true) == "goforward.15")
    #expect(SkipIntervalConfiguration.systemImage(seconds: 15, forward: false) == "gobackward.15")
    #expect(SkipIntervalConfiguration.systemImage(seconds: 75, forward: true) == "goforward.75")
    #expect(SkipIntervalConfiguration.systemImage(seconds: 90, forward: false) == "gobackward.90")
  }

  @Test("accessibility copy states each configured interval")
  func accessibilityCopyTracksInterval() {
    #expect(
      SkipIntervalConfiguration.accessibilityLabel(seconds: 45, forward: true)
        == "Skip forward 45 seconds")
    #expect(
      SkipIntervalConfiguration.accessibilityLabel(seconds: 45, forward: false)
        == "Skip back 45 seconds")
    #expect(
      SkipIntervalConfiguration.accessibilityHint(seconds: 45, forward: true)
        == "Moves playback 45 seconds later.")
    #expect(
      SkipIntervalConfiguration.accessibilityHint(seconds: 45, forward: false)
        == "Moves playback 45 seconds earlier.")
    #expect(SkipIntervalConfiguration.displayName(seconds: 1) == "1 second")
    #expect(SkipIntervalConfiguration.displayName(seconds: 30) == "30 seconds")
  }

  @Test("presets mirror the native playback menu choices")
  func presetsAreStable() {
    #expect(SkipIntervalConfiguration.presets == [10, 15, 30, 45, 60, 75, 90])
  }
}

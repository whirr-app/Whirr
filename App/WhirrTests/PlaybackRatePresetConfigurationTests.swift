import Foundation
import Testing

@testable import Whirr

@Suite("Playback rate preset configuration")
struct PlaybackRatePresetConfigurationTests {

  @Test("empty storage uses useful audiobook defaults")
  func emptyStorageUsesDefaults() {
    #expect(
      PlaybackRatePresetConfiguration.decode("").rates
        == [0.75, 1, 1.25, 1.5, 1.75, 2])
  }

  @Test("stored presets sort while snapping, deduplicating, and removing invalid values")
  func storedPresetsAreSanitized() {
    let configuration = PlaybackRatePresetConfiguration.decode(
      "1.33,0.49,1.35,3.01,2.5,nope,1.349"
    )

    #expect(configuration.rates == [1.35, 2.5])
    #expect(configuration.encoded == "1.35,2.5")
  }

  @Test("a newly entered lower speed sorts ahead of existing presets")
  func lowerSpeedSortsFirst() {
    let configuration = PlaybackRatePresetConfiguration(rates: [0.9, 0.95, 1, 1.05, 1.1, 0.85])

    #expect(configuration.rates == [0.85, 0.9, 0.95, 1, 1.05, 1.1])
    #expect(configuration.encoded == "0.85,0.9,0.95,1,1.05,1.1")
  }

  @Test("preset count is capped and editing always retains defaults")
  func presetCountAndEmptyFallback() {
    let configuration = PlaybackRatePresetConfiguration(
      rates: [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.25, 2.5])

    #expect(configuration.rates == [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.25])
    #expect(
      PlaybackRatePresetConfiguration(rates: []).rates
        == PlaybackRatePresetConfiguration.defaults)
  }

  @Test("display labels omit redundant decimal places")
  func displayLabels() {
    #expect(PlaybackRatePresetConfiguration.display(1) == "1×")
    #expect(PlaybackRatePresetConfiguration.display(1.5) == "1.5×")
    #expect(PlaybackRatePresetConfiguration.display(1.35) == "1.35×")
    #expect(PlaybackRatePresetConfiguration.display(1.05) == "1.05×")
  }

  @Test("normal speed is not worth printing beside the speedometer")
  func activeDisplayIsNilAtNormalSpeed() {
    #expect(PlaybackRatePresetConfiguration.activeDisplay(1) == nil)
  }

  @Test("a rate the listener changed still prints")
  func activeDisplayShowsAnAlteredRate() {
    #expect(PlaybackRatePresetConfiguration.activeDisplay(1.2) == "1.2×")
    #expect(PlaybackRatePresetConfiguration.activeDisplay(1.5) == "1.5×")
    #expect(PlaybackRatePresetConfiguration.activeDisplay(0.75) == "0.75×")
    #expect(PlaybackRatePresetConfiguration.activeDisplay(2) == "2×")
  }

  /// Rates arrive as `Double`s, so a value that merely rounds to 1× counts as normal. The label
  /// must not switch back on for a difference nobody can hear.
  @Test("a rate that rounds to normal counts as normal")
  func activeDisplayTreatsNearNormalRatesAsNormal() {
    #expect(PlaybackRatePresetConfiguration.activeDisplay(1.001) == nil)
  }

  @Test("non-finite playback rates have no label")
  func activeDisplayHidesNonFiniteRates() {
    #expect(PlaybackRatePresetConfiguration.activeDisplay(.nan) == nil)
    #expect(PlaybackRatePresetConfiguration.activeDisplay(.infinity) == nil)
  }

  // MARK: - Typed speeds (Custom Speed… and Settings' Add speed)

  @Test("a typed speed reads with a point or a comma, and with or without a multiplier sign")
  func typedSpeedAcceptsEitherSeparator() {
    let britain = Locale(identifier: "en_GB")
    #expect(PlaybackRatePresetConfiguration.parsedRate("1.25", locale: britain) == 1.25)
    #expect(PlaybackRatePresetConfiguration.parsedRate("1,25", locale: britain) == 1.25)
    #expect(PlaybackRatePresetConfiguration.parsedRate(" 1.5× ", locale: britain) == 1.5)
    #expect(PlaybackRatePresetConfiguration.parsedRate("2x", locale: britain) == 2)
    #expect(
      PlaybackRatePresetConfiguration.parsedRate("1,25", locale: Locale(identifier: "de_DE"))
        == 1.25)
  }

  @Test("text that is not a finite number is not a speed")
  func typedSpeedRejectsNonNumbers() {
    let britain = Locale(identifier: "en_GB")
    for text in ["", "  ", "fast", "1.2.3", "nan", "inf", "×"] {
      #expect(PlaybackRatePresetConfiguration.parsedRate(text, locale: britain) == nil, "\(text)")
    }
  }

  /// Rounded and clamped rather than refused: an alert cannot grey out its Set button, and the
  /// speed label shows what was applied, so nothing changes silently.
  @Test("a custom speed is rounded to 0.05× and kept within the custom range")
  func customSpeedRoundsAndClamps() {
    let britain = Locale(identifier: "en_GB")
    #expect(PlaybackRatePresetConfiguration.customRate(fromInput: "1.33", locale: britain) == 1.35)
    #expect(PlaybackRatePresetConfiguration.customRate(fromInput: "1,1", locale: britain) == 1.1)
    #expect(PlaybackRatePresetConfiguration.customRate(fromInput: "5", locale: britain) == 2)
    #expect(PlaybackRatePresetConfiguration.customRate(fromInput: "0.1", locale: britain) == 0.5)
    #expect(PlaybackRatePresetConfiguration.customRate(fromInput: "0", locale: britain) == 0.5)
    #expect(PlaybackRatePresetConfiguration.customRate(fromInput: "fast", locale: britain) == nil)
  }

  @Test("the custom speed field starts from the current speed in the listener's own notation")
  func customSpeedInputTextFollowsTheLocale() {
    #expect(PlaybackRatePresetConfiguration.inputText(1.1, locale: Locale(identifier: "en_GB")) == "1.1")
    #expect(PlaybackRatePresetConfiguration.inputText(1.1, locale: Locale(identifier: "de_DE")) == "1,1")
    #expect(PlaybackRatePresetConfiguration.inputText(1, locale: Locale(identifier: "en_GB")) == "1")
    #expect(PlaybackRatePresetConfiguration.inputText(0.95, locale: Locale(identifier: "en_GB")) == "0.95")
  }

  @Test("opening the custom speed prompt fills its field before it is shown")
  func customSpeedPromptPrefillsOnOpen() {
    var prompt = CustomSpeedPrompt()
    #expect(prompt.isPresented == false)
    prompt.open(currentRate: 1.35, locale: Locale(identifier: "en_GB"))
    #expect(prompt.isPresented)
    #expect(prompt.text == "1.35")
  }

  /// Settings hides its reset row when there is nothing to reset, and asks before resetting.
  @Test("the shortcuts know when they are the defaults and name them before a reset")
  func resetIsOfferedOnlyWhenCustomised() {
    #expect(PlaybackRatePresetConfiguration.decode("").isDefault)
    #expect(PlaybackRatePresetConfiguration.decode("2,1.75,1.5,1.25,1,0.75").isDefault)
    #expect(PlaybackRatePresetConfiguration.decode("1,1.05,1.1,1.2").isDefault == false)
    #expect(
      PlaybackRatePresetConfiguration.resetMessage
        == "Your speed shortcuts will go back to 0.75×, 1×, 1.25×, 1.5×, 1.75× and 2×.")
  }

}

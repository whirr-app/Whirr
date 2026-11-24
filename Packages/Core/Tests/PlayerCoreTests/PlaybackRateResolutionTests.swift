import Testing

@testable import PlayerCore

@Suite struct PlaybackRateResolutionTests {

  @Test func noOverrideUsesTheGlobalDefault() {
    let resolution = PlaybackRateResolution(overrideStep: nil, globalRate: 1.5)

    #expect(resolution.effectiveRate == 1.5)
    #expect(resolution.effectiveStep == 30)
  }

  @Test func overrideWinsOverTheGlobalDefault() {
    let resolution = PlaybackRateResolution(overrideStep: 36, globalRate: 1.25)

    #expect(resolution.effectiveRate == 1.8)
    #expect(resolution.effectiveStep == 36)
  }

  @Test func equalOverrideIsPinnedWhenTheGlobalDefaultLaterChanges() {
    let initial = PlaybackRateResolution(overrideStep: 36, globalRate: 1.8)
    let afterGlobalChange = PlaybackRateResolution(overrideStep: 36, globalRate: 1.25)

    #expect(initial.effectiveRate == 1.8)
    #expect(afterGlobalChange.effectiveRate == 1.8)
    #expect(afterGlobalChange.effectiveStep == 36)
  }

  @Test func invalidStoredOverrideIsTreatedAsNoOverride() {
    let resolution = PlaybackRateResolution(overrideStep: 61, globalRate: 1.5)

    #expect(resolution.effectiveRate == 1.5)
    #expect(resolution.effectiveStep == 30)
  }

  @Test func missingAndInvalidGlobalDefaultsFallBackToOneTimes() {
    #expect(
      PlaybackRateResolution(overrideStep: nil, globalRate: nil).effectiveRate == 1.0)
    #expect(
      PlaybackRateResolution(overrideStep: nil, globalRate: .nan).effectiveRate == 1.0)
    #expect(
      PlaybackRateResolution(overrideStep: nil, globalRate: 3.1).effectiveRate == 1.0)
  }

  @Test func supportedStepsAndRatesRoundTrip() {
    #expect(PlaybackRateResolution.rate(forStep: 10) == 0.5)
    #expect(PlaybackRateResolution.rate(forStep: 36) == 1.8)
    #expect(PlaybackRateResolution.rate(forStep: 60) == 3.0)
    #expect(PlaybackRateResolution.step(forRate: 0.5) == 10)
    #expect(PlaybackRateResolution.step(forRate: 1.8) == 36)
    #expect(PlaybackRateResolution.step(forRate: 3.0) == 60)
  }

  @Test func nonFiniteAndOutOfRangeValuesAreRejected() {
    #expect(PlaybackRateResolution.rate(forStep: 9) == nil)
    #expect(PlaybackRateResolution.rate(forStep: 61) == nil)
    #expect(PlaybackRateResolution.step(forRate: .nan) == nil)
    #expect(PlaybackRateResolution.step(forRate: .infinity) == nil)
    #expect(PlaybackRateResolution.step(forRate: 0.49) == nil)
    #expect(PlaybackRateResolution.step(forRate: 3.01) == nil)
  }

  // MARK: Focus speed

  @Test func focusSpeedWinsOverTheGlobalDefault() {
    let resolution = PlaybackRateResolution(
      overrideStep: nil, globalRate: 1.5, focusSpeed: FocusSpeed(rate: 0.9))

    #expect(resolution.effectiveRate == 0.9)
    #expect(resolution.effectiveStep == 18)
    #expect(resolution.appliesFocusSpeed)
  }

  @Test(arguments: [false, nil] as [Bool?])
  func focusSpeedWinsOverATitlesOwnSpeedUnlessSkipped(skips: Bool?) {
    let resolution = PlaybackRateResolution(
      overrideStep: 36, globalRate: 1.25,
      focusSpeed: FocusSpeed(rate: 0.9, skipsTitlesWithOwnSpeed: skips))

    #expect(resolution.effectiveRate == 0.9)
    #expect(resolution.appliesFocusSpeed)
  }

  @Test func skippingLeavesATitlesOwnSpeedAlone() {
    let resolution = PlaybackRateResolution(
      overrideStep: 36, globalRate: 1.25,
      focusSpeed: FocusSpeed(rate: 0.9, skipsTitlesWithOwnSpeed: true))

    #expect(resolution.effectiveRate == 1.8)
    #expect(!resolution.appliesFocusSpeed)
  }

  @Test func skippingStillReplacesTheGlobalDefault() {
    let resolution = PlaybackRateResolution(
      overrideStep: nil, globalRate: 1.25,
      focusSpeed: FocusSpeed(rate: 0.9, skipsTitlesWithOwnSpeed: true))

    #expect(resolution.effectiveRate == 0.9)
    #expect(resolution.appliesFocusSpeed)
  }

  @Test func skippingTreatsAnInvalidStoredOverrideAsNoOwnSpeed() {
    let resolution = PlaybackRateResolution(
      overrideStep: 61, globalRate: 1.25,
      focusSpeed: FocusSpeed(rate: 0.9, skipsTitlesWithOwnSpeed: true))

    #expect(resolution.effectiveRate == 0.9)
  }

  @Test(arguments: [Double.nan, .infinity, 0.49, 3.01])
  func invalidFocusRateIsIgnoredRatherThanClamped(rate: Double) {
    let withOverride = PlaybackRateResolution(
      overrideStep: 36, globalRate: 1.25, focusSpeed: FocusSpeed(rate: rate))
    let withoutOverride = PlaybackRateResolution(
      overrideStep: nil, globalRate: 1.25, focusSpeed: FocusSpeed(rate: rate))

    #expect(withOverride.effectiveRate == 1.8)
    #expect(withoutOverride.effectiveRate == 1.25)
    #expect(!withoutOverride.appliesFocusSpeed)
  }

  @Test func focusRateIsNormalizedToTwentieths() {
    let resolution = PlaybackRateResolution(
      overrideStep: nil, globalRate: nil, focusSpeed: FocusSpeed(rate: 0.912))

    #expect(resolution.effectiveRate == 0.9)
  }

  @Test func noFocusSpeedKeepsTheExistingPolicy() {
    let resolution = PlaybackRateResolution(overrideStep: 36, globalRate: 1.25, focusSpeed: nil)

    #expect(resolution.effectiveRate == 1.8)
    #expect(!resolution.appliesFocusSpeed)
  }

  @Test func rateInitializerPassesTheFocusSpeedThrough() {
    let skipped = PlaybackRateResolution(
      overrideRate: 1.8, globalRate: 1.25,
      focusSpeed: FocusSpeed(rate: 0.9, skipsTitlesWithOwnSpeed: true))
    let applied = PlaybackRateResolution(
      overrideRate: 1.8, globalRate: 1.25, focusSpeed: FocusSpeed(rate: 0.9))

    #expect(skipped.effectiveRate == 1.8)
    #expect(applied.effectiveRate == 0.9)
  }

  @Test func absentSkipSettingMeansOff() {
    #expect(FocusSpeed(rate: 0.9).skipsTitlesWithOwnSpeed == false)
    #expect(FocusSpeed(rate: 0.9, skipsTitlesWithOwnSpeed: nil).skipsTitlesWithOwnSpeed == false)
  }
}

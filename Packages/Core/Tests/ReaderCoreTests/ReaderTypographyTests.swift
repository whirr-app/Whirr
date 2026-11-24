import Testing

@testable import ReaderCore

@Suite struct ReaderTypographyTests {
  @Test func defaultPreferencesLeaveThePublicationInControl() {
    let typography = ReaderTypography(preferences: ReaderPreferences())

    #expect(typography.fontScale == 1.0)
    #expect(typography.lineHeight == 1.0)
    #expect(typography.pageMargins == 1.0)
    #expect(typography.wordSpacing == nil)
    #expect(typography.letterSpacing == nil)
    #expect(typography.paragraphSpacing == nil)
  }

  @Test func upperStepBoundsMapToTheRendererValues() {
    let typography = ReaderTypography(
      preferences: ReaderPreferences(
        fontSizeStep: ReaderPreferences.fontSizeStepBounds.upperBound,
        lineSpacingStep: ReaderPreferences.lineSpacingStepBounds.upperBound,
        marginsStep: ReaderPreferences.marginsStepBounds.upperBound,
        wordSpacingStep: ReaderPreferences.wordSpacingStepBounds.upperBound,
        letterSpacingStep: ReaderPreferences.letterSpacingStepBounds.upperBound,
        paragraphSpacingStep: ReaderPreferences.paragraphSpacingStepBounds.upperBound))

    #expect(typography.fontScale == 2.0)
    #expect(abs(typography.lineHeight - 1.4) < 1e-9)
    #expect(typography.pageMargins == 2.0)
    #expect(typography.wordSpacing == 1.0)
    #expect(typography.letterSpacing == 1.0)
    #expect(typography.paragraphSpacing == 2.0)
  }

  @Test(arguments: 0...8)
  func everyFontSizeStepAddsAnEighth(step: Int) {
    let typography = ReaderTypography(preferences: ReaderPreferences(fontSizeStep: step))
    #expect(typography.fontScale == 1.0 + Double(step) * 0.125)
  }

  @Test(arguments: 1...4)
  func everySpacingStepMapsLinearly(step: Int) {
    let typography = ReaderTypography(
      preferences: ReaderPreferences(
        lineSpacingStep: step, marginsStep: step, wordSpacingStep: step,
        letterSpacingStep: step, paragraphSpacingStep: step))

    #expect(abs(typography.lineHeight - (1.0 + Double(step) * 0.1)) < 1e-9)
    #expect(typography.pageMargins == 1.0 + Double(step) * 0.25)
    #expect(typography.wordSpacing == Double(step) * 0.25)
    #expect(typography.letterSpacing == Double(step) * 0.25)
    #expect(typography.paragraphSpacing == Double(step) * 0.5)
  }

  @Test func resettingTypographyKeepsThemeReadingModeAndCapability() {
    let customised = ReaderPreferences(
      theme: .sepia, fontFamily: .monospaced, fontSizeStep: 5, lineSpacingStep: 3,
      marginsStep: 2, readingMode: .scroll, textAlignment: .justify, wordSpacingStep: 1,
      letterSpacingStep: 2, paragraphSpacingStep: 3, hyphenation: true, publisherStyles: false,
      reflowable: true)

    let reset = customised.resettingTypography()

    #expect(
      reset
        == ReaderPreferences(theme: .sepia, readingMode: .scroll, reflowable: true))
  }
}

import Foundation
import Testing

@testable import ReaderCore

@Suite struct ReaderPreferencesTests {

  @Test func defaultReaderPreferencesUsePublisherControlledTextAlignment() {
    #expect(ReaderPreferences().textAlignment == .publisherDefault)
  }

  @Test func preRV1JSONDefaultsToPublisherControlledTextAlignment() throws {
    let legacyJSON =
      #"{"theme":"sepia","fontFamily":"serif","fontSizeStep":3,"lineSpacingStep":2,"marginsStep":1,"readingMode":"scroll","reflowable":false}"#

    let decoded = try JSONDecoder().decode(
      ReaderPreferences.self,
      from: Data(legacyJSON.utf8))
    let expected = ReaderPreferences(
      theme: .sepia,
      fontFamily: .serif,
      fontSizeStep: 3,
      lineSpacingStep: 2,
      marginsStep: 1,
      readingMode: .scroll,
      publisherStyles: false,
      reflowable: false)

    #expect(decoded == expected)
    #expect(decoded.textAlignment == .publisherDefault)
    #expect(decoded.publisherStyles == false)
  }

  @Test func publisherStylesMigrationUsesTheLegacyRuleOnlyWhenTheKeyIsMissing() throws {
    let legacyChangedAlignment =
      #"{"theme":"light","fontFamily":"serif","fontSizeStep":0,"lineSpacingStep":0,"marginsStep":0,"readingMode":"paginated","textAlignment":"justify","reflowable":true}"#
    let legacyUnchangedTypography =
      #"{"theme":"light","fontFamily":"serif","fontSizeStep":0,"lineSpacingStep":0,"marginsStep":0,"readingMode":"paginated","textAlignment":"publisherDefault","reflowable":true}"#
    let explicitPublisherStyles =
      #"{"theme":"light","fontFamily":"serif","fontSizeStep":0,"lineSpacingStep":0,"marginsStep":0,"readingMode":"paginated","textAlignment":"justify","publisherStyles":true,"reflowable":true}"#

    let changedAlignment = try JSONDecoder().decode(
      ReaderPreferences.self,
      from: Data(legacyChangedAlignment.utf8))
    let unchangedTypography = try JSONDecoder().decode(
      ReaderPreferences.self,
      from: Data(legacyUnchangedTypography.utf8))
    let explicitValue = try JSONDecoder().decode(
      ReaderPreferences.self,
      from: Data(explicitPublisherStyles.utf8))

    #expect(changedAlignment.publisherStyles == false)
    #expect(unchangedTypography.publisherStyles == true)
    #expect(explicitValue.publisherStyles == true)
  }

  @Test func readerTextAlignmentRoundTripsEveryCase() throws {
    for textAlignment in ReaderTextAlignment.allCases {
      let preferences = ReaderPreferences(
        theme: .dark,
        fontFamily: .sansSerif,
        fontSizeStep: 2,
        lineSpacingStep: 1,
        marginsStep: 3,
        readingMode: .scroll,
        textAlignment: textAlignment,
        reflowable: false)

      let data = try JSONEncoder().encode(preferences)
      let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)

      #expect(decoded == preferences)
    }
  }

  @Test func changingReaderPreferenceFieldsPreservesTheOtherFields() {
    let original = ReaderPreferences(
      theme: .dark,
      fontFamily: .sansSerif,
      fontSizeStep: 4,
      lineSpacingStep: 3,
      marginsStep: 2,
      readingMode: .scroll,
      textAlignment: .justify,
      reflowable: false)

    var marginsChanged = original
    marginsChanged.marginsStep = 4
    #expect(marginsChanged.textAlignment == .justify)
    #expect(
      marginsChanged
        == ReaderPreferences(
          theme: .dark,
          fontFamily: .sansSerif,
          fontSizeStep: 4,
          lineSpacingStep: 3,
          marginsStep: 4,
          readingMode: .scroll,
          textAlignment: .justify,
          reflowable: false))

    var alignmentChanged = original
    alignmentChanged.textAlignment = .left
    #expect(
      alignmentChanged
        == ReaderPreferences(
          theme: .dark,
          fontFamily: .sansSerif,
          fontSizeStep: 4,
          lineSpacingStep: 3,
          marginsStep: 2,
          readingMode: .scroll,
          textAlignment: .left,
          reflowable: false))
  }

  @Test func invalidStoredTextAlignmentFallsBackToPublisherDefault() throws {
    let storedJSON =
      #"{"theme":"dark","fontFamily":"serif","fontSizeStep":2,"lineSpacingStep":1,"marginsStep":3,"readingMode":"scroll","reflowable":true,"textAlignment":"garbage"}"#

    let decoded = try JSONDecoder().decode(
      ReaderPreferences.self,
      from: Data(storedJSON.utf8))

    #expect(decoded.textAlignment == .publisherDefault)
  }

  @Test func unknownStoredFontFamilyFallsBackToPublisherDefault() throws {
    let storedJSON =
      #"{"theme":"dark","fontFamily":"futureFont","fontSizeStep":2,"lineSpacingStep":1,"marginsStep":3,"readingMode":"scroll","reflowable":true}"#

    let decoded = try JSONDecoder().decode(
      ReaderPreferences.self,
      from: Data(storedJSON.utf8))

    #expect(decoded.fontFamily == .publisherDefault)
  }

  @Test func readerPreferencesJSONRoundTripsLosslessly() throws {
    let preferences = ReaderPreferences(
      theme: .sepia,
      fontFamily: .openDyslexic,
      fontSizeStep: 3,
      lineSpacingStep: 2,
      marginsStep: 1,
      readingMode: .scroll,
      wordSpacingStep: 4,
      letterSpacingStep: 3,
      paragraphSpacingStep: 2,
      hyphenation: true,
      publisherStyles: false,
      reflowable: false
    )

    let data = try JSONEncoder().encode(preferences)
    let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)

    #expect(decoded == preferences)
  }

  @Test func unknownFutureFieldsAreIgnored() throws {
    let original = ReaderPreferences(
      theme: .dark,
      fontFamily: .sansSerif,
      fontSizeStep: 2,
      lineSpacingStep: 1,
      marginsStep: 3,
      readingMode: .paginated
    )
    var object = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
    )
    object["futureReaderPreference"] = ["newChoice": "newValue"]

    let data = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)

    #expect(decoded == original)
  }

  @Test func defaultsMatchTheInitialPaginatedPublisherSystemExperience() {
    let preferences = ReaderPreferences()

    #expect(preferences.theme == .system)
    #expect(preferences.fontFamily == .publisherDefault)
    #expect(preferences.fontSizeStep == ReaderPreferences.defaultFontSizeStep)
    #expect(preferences.lineSpacingStep == ReaderPreferences.defaultLineSpacingStep)
    #expect(preferences.marginsStep == ReaderPreferences.defaultMarginsStep)
    #expect(preferences.wordSpacingStep == ReaderPreferences.defaultWordSpacingStep)
    #expect(preferences.letterSpacingStep == ReaderPreferences.defaultLetterSpacingStep)
    #expect(preferences.paragraphSpacingStep == ReaderPreferences.defaultParagraphSpacingStep)
    #expect(preferences.hyphenation == ReaderPreferences.defaultHyphenation)
    #expect(preferences.publisherStyles == ReaderPreferences.defaultPublisherStyles)
    #expect(preferences.readingMode == .paginated)
    #expect(preferences.reflowable)
    #expect(preferences.fixedLayout == false)
  }

  @Test func stepIncrementAndDecrementClampAtDocumentedBounds() {
    var preferences = ReaderPreferences(
      fontSizeStep: ReaderPreferences.fontSizeStepBounds.upperBound,
      lineSpacingStep: ReaderPreferences.lineSpacingStepBounds.upperBound,
      marginsStep: ReaderPreferences.marginsStepBounds.upperBound,
      wordSpacingStep: ReaderPreferences.wordSpacingStepBounds.upperBound,
      letterSpacingStep: ReaderPreferences.letterSpacingStepBounds.upperBound,
      paragraphSpacingStep: ReaderPreferences.paragraphSpacingStepBounds.upperBound
    )

    preferences.incrementFontSizeStep()
    preferences.incrementLineSpacingStep()
    preferences.incrementMarginsStep()
    preferences.incrementWordSpacingStep()
    preferences.incrementLetterSpacingStep()
    preferences.incrementParagraphSpacingStep()
    #expect(preferences.fontSizeStep == ReaderPreferences.fontSizeStepBounds.upperBound)
    #expect(preferences.lineSpacingStep == ReaderPreferences.lineSpacingStepBounds.upperBound)
    #expect(preferences.marginsStep == ReaderPreferences.marginsStepBounds.upperBound)
    #expect(preferences.wordSpacingStep == ReaderPreferences.wordSpacingStepBounds.upperBound)
    #expect(preferences.letterSpacingStep == ReaderPreferences.letterSpacingStepBounds.upperBound)
    #expect(
      preferences.paragraphSpacingStep == ReaderPreferences.paragraphSpacingStepBounds.upperBound)

    preferences.fontSizeStep = ReaderPreferences.fontSizeStepBounds.lowerBound
    preferences.lineSpacingStep = ReaderPreferences.lineSpacingStepBounds.lowerBound
    preferences.marginsStep = ReaderPreferences.marginsStepBounds.lowerBound
    preferences.wordSpacingStep = ReaderPreferences.wordSpacingStepBounds.lowerBound
    preferences.letterSpacingStep = ReaderPreferences.letterSpacingStepBounds.lowerBound
    preferences.paragraphSpacingStep = ReaderPreferences.paragraphSpacingStepBounds.lowerBound
    preferences.decrementFontSizeStep()
    preferences.decrementLineSpacingStep()
    preferences.decrementMarginsStep()
    preferences.decrementWordSpacingStep()
    preferences.decrementLetterSpacingStep()
    preferences.decrementParagraphSpacingStep()
    #expect(preferences.fontSizeStep == ReaderPreferences.fontSizeStepBounds.lowerBound)
    #expect(preferences.lineSpacingStep == ReaderPreferences.lineSpacingStepBounds.lowerBound)
    #expect(preferences.marginsStep == ReaderPreferences.marginsStepBounds.lowerBound)
    #expect(preferences.wordSpacingStep == ReaderPreferences.wordSpacingStepBounds.lowerBound)
    #expect(preferences.letterSpacingStep == ReaderPreferences.letterSpacingStepBounds.lowerBound)
    #expect(
      preferences.paragraphSpacingStep == ReaderPreferences.paragraphSpacingStepBounds.lowerBound)
  }

  @Test func initializersClampStepsBeforeIncrementingOrDecrementing() {
    let preferences = ReaderPreferences(
      fontSizeStep: Int.min,
      lineSpacingStep: Int.max,
      marginsStep: Int.min,
      wordSpacingStep: Int.min,
      letterSpacingStep: Int.max,
      paragraphSpacingStep: Int.min
    )

    #expect(preferences.fontSizeStep == ReaderPreferences.fontSizeStepBounds.lowerBound)
    #expect(preferences.lineSpacingStep == ReaderPreferences.lineSpacingStepBounds.upperBound)
    #expect(preferences.marginsStep == ReaderPreferences.marginsStepBounds.lowerBound)
    #expect(preferences.wordSpacingStep == ReaderPreferences.wordSpacingStepBounds.lowerBound)
    #expect(preferences.letterSpacingStep == ReaderPreferences.letterSpacingStepBounds.upperBound)
    #expect(preferences.paragraphSpacingStep == ReaderPreferences.paragraphSpacingStepBounds.lowerBound)

    var assigned = preferences
    assigned.wordSpacingStep = Int.max
    assigned.letterSpacingStep = Int.min
    assigned.paragraphSpacingStep = Int.max
    #expect(assigned.wordSpacingStep == ReaderPreferences.wordSpacingStepBounds.upperBound)
    #expect(assigned.letterSpacingStep == ReaderPreferences.letterSpacingStepBounds.lowerBound)
    #expect(assigned.paragraphSpacingStep == ReaderPreferences.paragraphSpacingStepBounds.upperBound)
  }

  @Test func fixedLayoutCapabilityIsAvailableToDisableReflowControls() {
    let preferences = ReaderPreferences(reflowable: false)

    #expect(preferences.reflowable == false)
    #expect(preferences.fixedLayout)
  }
  @Test func footerReadoutDefaultsToThePage() {
    #expect(ReaderPreferences().footerReadout == .page)
  }

  @Test func footerReadoutMissingOrUnknownFallsBackToThePage() throws {
    let missing = #"{"theme":"dark","readingMode":"paginated","reflowable":true}"#
    let unknown =
      #"{"theme":"dark","readingMode":"paginated","reflowable":true,"footerReadout":"future"}"#

    for json in [missing, unknown] {
      let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: Data(json.utf8))
      #expect(decoded.footerReadout == .page)
      #expect(decoded.theme == .dark)
    }
  }

  @Test func footerReadoutRoundTripsEveryCase() throws {
    for readout in ReaderFooterReadout.allCases {
      let preferences = ReaderPreferences(theme: .sepia, footerReadout: readout)
      let data = try JSONEncoder().encode(preferences)
      let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
      #expect(decoded == preferences)
    }
  }

  @Test func footerReadoutsCycleFromThePageThroughChapterTimeToPercent() {
    #expect(ReaderFooterReadout.allCases == [.page, .chapterTimeLeft, .percent])
  }

  @Test func resettingTypographyKeepsTheFooterReadout() {
    let customised = ReaderPreferences(fontSizeStep: 4, footerReadout: .percent)
    #expect(customised.resettingTypography().footerReadout == .percent)
  }
}

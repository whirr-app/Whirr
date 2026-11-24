import Foundation
import Testing

@testable import AppModel

@Suite("Reader copy")
struct ReaderCopyTests {

  @Test("reader search states have distinct caller-owned copy")
  func readerSearchStatesHaveDistinctCallerOwnedCopy() {
    let states = [
      ReaderCopy.searchNothingTyped,
      ReaderCopy.searchSearching,
      ReaderCopy.searchNoMatches,
      ReaderCopy.searchFailed,
      ReaderCopy.searchResultLimit,
    ]

    #expect(states.allSatisfy { $0.isEmpty == false })
    #expect(Set(states).count == states.count)
  }

  @Test("spacing and margin values are words, never numbers", arguments: 0...4)
  func spacingValuesAreWords(step: Int) {
    let values = [
      ReaderCopy.lineSpacingValue(step: step), ReaderCopy.wordSpacingValue(step: step),
      ReaderCopy.letterSpacingValue(step: step), ReaderCopy.paragraphSpacingValue(step: step),
      ReaderCopy.marginsValue(step: step),
    ]
    #expect(values.allSatisfy { $0.rangeOfCharacter(from: .decimalDigits) == nil })
  }

  @Test("the fallback sample is more than one paragraph, so paragraph spacing shows")
  func fallbackSampleHasTwoParagraphs() {
    #expect(ReaderCopy.typographySampleFallback.split(separator: "\n").count == 2)
  }

  @Test("the readout gives the page and percentage, shortening the page when asked")
  func readoutPositionGivesPageAndPercentage() {
    #expect(
      ReaderCopy.readoutPosition(percentText: "28%", page: 112, pageCount: 402, isCompact: false)
        == "Page 112 of 402 · 28%")
    #expect(
      ReaderCopy.readoutPosition(percentText: "28%", page: 112, pageCount: 402, isCompact: true)
        == "112 of 402 · 28%")
  }

  @Test("the return offer names the page left behind, or its percentage without pages")
  func backToPositionNamesThePage() {
    #expect(ReaderCopy.backToPosition(page: 259, percentText: "51%") == "Back to page 259")
    #expect(ReaderCopy.backToPosition(page: nil, percentText: "51%") == "Back to 51%")
    #expect(ReaderCopy.backToPosition(page: 0, percentText: "51%") == "Back to 51%")
  }

  @Test("without valid pages the readout is the percentage alone")
  func readoutPositionFallsBackToPercentage() {
    #expect(
      ReaderCopy.readoutPosition(percentText: "28%", page: nil, pageCount: nil, isCompact: false)
        == "28%")
    #expect(
      ReaderCopy.readoutPosition(percentText: "28%", page: 0, pageCount: 402, isCompact: true)
        == "28%")
  }

  @Test("rail VoiceOver copy combines percent and known page copy")
  func railVoiceOverCopyCombinesPercentAndKnownPage() {
    #expect(
      ReaderCopy.progressAccessibilityValue(
        percentText: "12%", pageText: "Page 42 of 336")
        == "Reading progress, 12 percent, Page 42 of 336"
    )
  }

  @Test("appearance values render the renderer's own mappings, clamped at the low end")
  func appearanceValuesRenderRendererMappings() {
    #expect(ReaderCopy.fontSizeValue(step: 0) == "100%")
    #expect(ReaderCopy.fontSizeValue(step: 4) == "150%")
    #expect(ReaderCopy.fontSizeValue(step: 8) == "200%")
    #expect(ReaderCopy.fontSizeValue(step: -1) == "100%")

    #expect(ReaderCopy.lineSpacingValue(step: 0) == "Default")
    #expect(ReaderCopy.lineSpacingValue(step: 4) == "Widest")
    #expect(ReaderCopy.lineSpacingValue(step: -1) == "Default")

    #expect(ReaderCopy.wordSpacingValue(step: 0) == "Default")
    #expect(ReaderCopy.wordSpacingValue(step: 4) == "Widest")
    #expect(ReaderCopy.wordSpacingValue(step: -1) == "Default")
    #expect(ReaderCopy.letterSpacingValue(step: 2) == "Wider")
    #expect(ReaderCopy.paragraphSpacingValue(step: 0) == "Default")
    #expect(ReaderCopy.paragraphSpacingValue(step: 4) == "Widest")

    #expect(ReaderCopy.marginsValue(step: 0) == "Default")
    #expect(ReaderCopy.marginsValue(step: 2) == "Medium")
    #expect(ReaderCopy.marginsValue(step: 4) == "Widest")
    // Out-of-range steps clamp rather than trap: the value copy must never crash the panel.
    #expect(ReaderCopy.marginsValue(step: 9) == "Widest")
    #expect(ReaderCopy.marginsValue(step: -3) == "Default")
  }

  @Test("brightness values render whole percentages and clamp to the screen range")
  func brightnessValuesRenderWholePercentagesAndClampToTheScreenRange() {
    #expect(ReaderCopy.brightnessValue(0.0) == "0%")
    #expect(ReaderCopy.brightnessValue(0.425) == "43%")
    #expect(ReaderCopy.brightnessValue(1.0) == "100%")
    #expect(ReaderCopy.brightnessValue(-0.2) == "0%")
    #expect(ReaderCopy.brightnessValue(1.2) == "100%")
  }

  @Test("rail VoiceOver copy keeps percent when page copy is unknown")
  func railVoiceOverCopyKeepsPercentWithoutPage() {
    #expect(
      ReaderCopy.progressAccessibilityValue(percentText: "12%", pageText: nil)
        == "Reading progress, 12 percent"
    )
  }

  @Test("reading time copy omits estimates below one minute")
  func readingTimeCopyOmitsEstimatesBelowOneMinute() {
    #expect(ReaderCopy.chapterTimeRemaining(seconds: 59.9) == nil)
    #expect(ReaderCopy.bookTimeRemaining(seconds: -1) == nil)
  }

  @Test("reading time copy formats minute and hour estimates")
  func readingTimeCopyFormatsMinuteAndHourEstimates() {
    #expect(
      ReaderCopy.chapterTimeRemaining(seconds: 12 * 60 + 20)
        == "12 min left in chapter"
    )
    #expect(
      ReaderCopy.bookTimeRemaining(seconds: 5 * 60 * 60 + 20 * 60)
        == "About 5 hr 20 min left in book"
    )
    #expect(ReaderCopy.bookTimeRemaining(seconds: 5 * 60 * 60) == "About 5 hr left in book")
  }

  @Test("progress text appends the book estimate")
  func progressTextAppendsTheBookEstimate() {
    #expect(
      ReaderCopy.progressText(
        progress: 0.42,
        chapterTitle: "Chapter 2",
        page: 2,
        pageCount: 10,
        bookTimeRemainingText: "About 5 min left in book")
        == "42% · Chapter 2 · Page 2 of 10 · About 5 min left in book"
    )
  }

  @Test("reader controls action names the control that is available")
  func readerControlsActionNamesTheControlThatIsAvailable() {
    #expect(
      ReaderCopy.readerControlsActionLabel(chromeVisible: true)
        == "Hide reader controls"
    )
    #expect(
      ReaderCopy.readerControlsActionLabel(chromeVisible: false)
        == "Show reader controls"
    )
  }
}

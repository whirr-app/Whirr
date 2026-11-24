import Testing

@testable import AppModel

@Suite("ReaderDetailCopy")
struct ReaderDetailCopyTests {
  /// The title carries no percentage, since the subtitle owns it. Otherwise "Continue reading 3%",
  /// "3%" and a progress indicator would show the same figure three times on one row.
  @Test("the continue-reading title carries no percentage")
  func continueReadingTitleCarriesNoPercentage() {
    #expect(ReaderDetailCopy.continueReadingTitle.contains("%") == false)
  }

  @Test("the percentage subtitle is the percentage alone")
  func percentageSubtitleIsThePercentageAlone() {
    #expect(ReaderDetailCopy.percentRead(percent: 3) == "3%")
    #expect(ReaderDetailCopy.percentRead(percent: 42) == "42%")
  }

  /// VoiceOver reads one label rather than the visual row's two halves, so the spoken label keeps
  /// the percentage once.
  @Test("the spoken label states the percentage exactly once")
  func spokenLabelStatesThePercentageExactlyOnce() {
    let label = ReaderDetailCopy.continueReading(percent: 3)
    #expect(label == "Continue reading 3%")
    #expect(label.components(separatedBy: "3%").count == 2)
  }

  /// The detail screen's reader action is one prominent bar, the shape the audiobook play button
  /// already has, so like it the title names only the tap. The remaining figure sits on the
  /// detail progress line beside the bar.
  @Test("the detail action title mirrors the play button's shape")
  func detailActionTitleMirrorsThePlayButton() {
    #expect(ReaderDetailCopy.detailActionTitle(for: .read, isFinished: false) == "Read")
    #expect(
      ReaderDetailCopy.detailActionTitle(for: .continueReading(percent: 37), isFinished: false)
        == "Continue reading")
  }

  @Test("the reading remainder and its bar are gated together")
  func readingRemainderAndBarAreGatedTogether() {
    #expect(ReaderDetailCopy.detailReadingRemaining(for: .continueReading(percent: 37)) == "63% left")
    #expect(ReaderDetailCopy.detailReadingFraction(for: .continueReading(percent: 37)) == 0.37)

    // Unstarted, finished, and non-reading states render neither.
    for state in [
      ReadAffordanceState.continueReading(percent: 0), .continueReading(percent: 100), .read, .none,
    ] {
      #expect(ReaderDetailCopy.detailReadingRemaining(for: state) == nil)
      #expect(ReaderDetailCopy.detailReadingFraction(for: state) == nil)
    }
  }

  /// A finished book still offers a read action, so it can be opened again. It gets the same
  /// prominent bar, saying what tapping it does.
  @Test("a finished book's action reads as a re-read")
  func finishedBookOffersAReRead() {
    #expect(ReaderDetailCopy.detailActionTitle(for: .read, isFinished: true) == "Read Again")
    #expect(
      ReaderDetailCopy.detailActionTitle(for: .continueReading(percent: 100), isFinished: true)
        == "Read Again")
  }

  /// Nothing is left to read, but the book was never marked finished. The parenthetical would
  /// say "(0% left)", so it is dropped rather than rendered.
  @Test("an unfinished book with nothing left drops the parenthetical")
  func nothingLeftDropsTheParenthetical() {
    #expect(
      ReaderDetailCopy.detailActionTitle(for: .continueReading(percent: 100), isFinished: false)
        == "Continue reading")
  }

  @Test("states with no read action have no title")
  func statesWithoutAnActionHaveNoTitle() {
    #expect(ReaderDetailCopy.detailActionTitle(for: .none, isFinished: false) == nil)
    #expect(
      ReaderDetailCopy.detailActionTitle(for: .downloading(progress: 0.5), isFinished: false)
        == nil)
    #expect(
      ReaderDetailCopy.detailActionTitle(for: .advertisedButUnavailable, isFinished: true) == nil)
  }
}

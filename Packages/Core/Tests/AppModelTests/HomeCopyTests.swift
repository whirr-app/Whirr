import Testing

@testable import AppModel

@Suite("Home copy")
struct HomeCopyTests {

  /// The full-screen empty state is one sentence. Joining every section's own empty line would
  /// read as near-identical sentences and repeat "Nothing in progress yet." because Continue
  /// Listening and Continue Reading share that copy.
  @Test("the all-sections-empty message is a single sentence, not the section lines joined")
  func allSectionsEmptyMessageIsOneSentence() {
    let message = HomeCopy.allSectionsEmptyMessage

    #expect(message.isEmpty == false)
    #expect(message.filter { $0 == "." }.count == 1)
    #expect(message.contains(HomeCopy.continueListeningEmpty) == false)
    #expect(message.contains(HomeCopy.recentlyAddedEmpty) == false)
    #expect(message.contains(HomeCopy.downloadedEmpty) == false)
  }

  /// The two "Continue" sections share an empty line, so a consumer emitting both would repeat the
  /// same sentence. The single message exists to prevent that.
  @Test("the two continue sections share an empty line, so joining them would repeat")
  func continueSectionsShareTheSameEmptyLine() {
    #expect(HomeCopy.continueListeningEmpty == HomeCopy.continueReadingEmpty)
  }

  @Test("continue card hints describe the action performed by tapping")
  func continueCardHintsDescribeTapAction() {
    #expect(
      HomeCopy.continueCardHint(for: .audiobook, in: .continueListening)
        == "Resumes playback.")
    #expect(
      HomeCopy.continueCardHint(for: .podcast, in: .continueListening)
        == "Resumes playback.")
    #expect(
      HomeCopy.continueCardHint(
        for: .audiobook, in: .continueListening,
        opensContinueCardImmediately: false)
        == "Opens details.")
    #expect(
      HomeCopy.continueCardHint(
        for: .podcast, in: .continueListening,
        opensContinueCardImmediately: false)
        == "Opens details.")
    #expect(
      HomeCopy.continueCardHint(for: .ebook, in: .continueListening) == nil)
    #expect(
      HomeCopy.continueCardHint(
        for: .ebook, in: .continueReading,
        opensContinueCardImmediately: false)
        == "Opens details.")
    #expect(
      HomeCopy.continueCardHint(for: .ebook, in: .continueReading)
        == "Opens the reader.")
    #expect(HomeCopy.continueCardHint(for: .audiobook, in: .recentlyAdded) == nil)
  }

  @Test("latest episodes has one canonical label on every surface")
  func latestEpisodesHasOneCanonicalLabel() {
    #expect(HomeCopy.sectionTitle(.newEpisodes) == HomeCopy.latestEpisodesTitle)
    #expect(HomeCopy.moreTitle(section: .newEpisodes, filter: .all) == HomeCopy.latestEpisodesTitle)
    #expect(
      HomeCopy.moreTitle(section: .newEpisodes, filter: .podcasts)
        == HomeCopy.latestEpisodesTitle)
  }

  @Test("Saved for Later has one canonical title and empty message")
  func savedForLaterHasCanonicalCopy() {
    // The shelf says it clears itself.
    #expect(
      HomeCopy.savedForLaterEmpty
        == "Save a book or podcast episode to find it here. It leaves this shelf once you start it.")
    #expect(HomeCopy.sectionTitle(.savedForLater) == HomeCopy.savedForLaterTitle)
    #expect(
      HomeCopy.moreTitle(section: .savedForLater, filter: .all)
        == HomeCopy.savedForLaterTitle)
    #expect(
      HomeCopy.moreEmptyMessage(section: .savedForLater, filter: .podcasts)
        == HomeCopy.savedForLaterEmpty)
  }

  /// Saved for Later filters in place, so an empty result there usually means "nothing of this
  /// kind is saved", not "nothing is saved". The unfiltered copy would state the stronger and
  /// wrong thing over a shelf that still holds items under the other chips.
  @Test("an empty filtered saved shelf names the kind rather than claiming the shelf is bare")
  func savedForLaterEmptyCopyFollowsTheFilter() {
    #expect(HomeCopy.savedForLaterEmptyTitle(for: .all) == "Nothing Saved Yet")
    #expect(HomeCopy.savedForLaterEmptyTitle(for: .audiobooks) == "No Saved Audiobooks")
    #expect(HomeCopy.savedForLaterEmptyTitle(for: .podcasts) == "No Saved Podcasts")
    #expect(HomeCopy.savedForLaterEmptyTitle(for: .ebooks) == "No Saved eBooks")

    #expect(HomeCopy.savedForLaterEmpty(for: .all) == HomeCopy.savedForLaterEmpty)
    #expect(
      HomeCopy.savedForLaterEmpty(for: .audiobooks)
        == "Your saved shelf has no audiobooks yet.")
    #expect(
      HomeCopy.savedForLaterEmpty(for: .ebooks)
        == "Your saved shelf has no eBooks yet.")
    // Podcasts are saved one episode at a time, so the noun is the episode, not the show.
    #expect(
      HomeCopy.savedForLaterEmpty(for: .podcasts)
        == "Your saved shelf has no podcast episodes yet.")
  }

  /// The unfiltered constants stay the single source the filtered helpers fall back to.
  @Test("the unfiltered saved copy is what the all filter resolves to")
  func savedForLaterUnfilteredCopyIsTheFallback() {
    #expect(HomeCopy.savedForLaterEmptyTitle(for: .all) == HomeCopy.savedForLaterEmptyTitle)
    #expect(
      HomeCopy.moreEmptyMessage(section: .savedForLater, filter: .all)
        == HomeCopy.savedForLaterEmpty(for: .all))
  }
}

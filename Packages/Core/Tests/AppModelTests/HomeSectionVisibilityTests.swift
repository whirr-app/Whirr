import Testing

@testable import AppModel

@Suite("Home section visibility")
struct HomeSectionVisibilityTests {

  @Test("nothing is hidden by default")
  func emptyStoreHidesNothing() {
    #expect(HomeSectionVisibility.hidden(in: "").isEmpty)
    for section in HomeMoreSection.allCases {
      #expect(HomeSectionVisibility.isVisible(section, in: "") == true)
    }
  }

  @Test("hidden sections round-trip through the stored string in display order")
  func hiddenSectionsRoundTrip() {
    let stored = HomeSectionVisibility.stored(hidden: [.downloaded, .continueListening])
    #expect(stored == "continueListening,downloaded")
    #expect(HomeSectionVisibility.hidden(in: stored) == [.continueListening, .downloaded])
  }

  @Test("unknown and empty tokens are ignored rather than corrupting the whole preference")
  func unknownTokensAreIgnored() {
    let hidden = HomeSectionVisibility.hidden(in: ",recentlyAdded,,notASection, downloaded ")
    #expect(hidden == [.recentlyAdded, .downloaded])
  }

  @Test("toggling a section off then on returns to the original preference")
  func togglingIsReversible() {
    let hiddenOnce = HomeSectionVisibility.updating("", section: .newEpisodes, isVisible: false)
    #expect(HomeSectionVisibility.isVisible(.newEpisodes, in: hiddenOnce) == false)
    #expect(HomeSectionVisibility.isVisible(.recentlyAdded, in: hiddenOnce) == true)

    let restored = HomeSectionVisibility.updating(
      hiddenOnce, section: .newEpisodes, isVisible: true)
    #expect(restored == "")
  }

  @Test("hiding the same section twice does not duplicate it")
  func hidingIsIdempotent() {
    var stored = HomeSectionVisibility.updating("", section: .continueSeries, isVisible: false)
    stored = HomeSectionVisibility.updating(stored, section: .continueSeries, isVisible: false)
    #expect(stored == "continueSeries")
  }

  @Test("every section has a settings label matching its on-screen title")
  func sectionTitlesMatchTheHomeScreen() {
    #expect(HomeCopy.sectionTitle(.continueListening) == HomeCopy.continueListeningTitle)
    #expect(HomeCopy.sectionTitle(.continueReading) == HomeCopy.continueReadingTitle)
    #expect(HomeCopy.sectionTitle(.continueSeries) == HomeCopy.continueSeriesTitle)
    #expect(HomeCopy.sectionTitle(.newEpisodes) == HomeCopy.latestEpisodesTitle)
    #expect(HomeCopy.sectionTitle(.recentlyAdded) == HomeCopy.recentlyAddedTitle)
    #expect(HomeCopy.sectionTitle(.downloaded) == HomeCopy.downloadedTitle)
    #expect(HomeCopy.sectionTitle(.savedForLater) == HomeCopy.savedForLaterTitle)
    #expect(HomeCopy.sectionTitle(.listeningStats) == ListeningStatsCopy.title)
  }
}

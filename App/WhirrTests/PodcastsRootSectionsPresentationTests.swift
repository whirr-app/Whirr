import AppModel
import Testing

@testable import Whirr

@Suite("Podcasts root sections")
struct PodcastsRootSectionsPresentationTests {
  private func drawn(
    hidden: String = "", order: String = "",
    continueListening: Bool = true, latest: Bool = true, smartLists: Bool = true,
    shows: Bool = true
  ) -> [PodcastsRootSection] {
    PodcastsViewPresentation.drawnRootSections(
      visible: PodcastsViewPresentation.visibleRootSections(
        hiddenSections: hidden, sectionOrder: order),
      hasContinueListening: continueListening,
      hasLatestEpisodes: latest,
      hasSmartLists: smartLists,
      showsSectionIsReachable: shows)
  }

  @Test("default preferences draw the sections in their default order, Smart Lists before shows")
  func defaultLayoutPlacesSmartListsBeforeShows() {
    #expect(drawn() == [.continueListening, .latestEpisodes, .smartLists, .yourShows])
    #expect(
      drawn(smartLists: false) == [.continueListening, .latestEpisodes, .yourShows])
  }

  @Test("a hidden section is not drawn")
  func hiddenSectionsAreNotDrawn() {
    #expect(drawn(hidden: "latestEpisodes") == [.continueListening, .smartLists, .yourShows])
    #expect(drawn(hidden: "continueListening,smartLists,yourShows") == [.latestEpisodes])
  }

  @Test("the stored order is honoured")
  func orderIsHonoured() {
    #expect(
      drawn(order: "yourShows,continueListening,latestEpisodes")
        == [.yourShows, .continueListening, .latestEpisodes, .smartLists])
  }

  @Test("an empty section is not drawn, whatever its position")
  func emptySectionsAreSkipped() {
    #expect(
      drawn(order: "yourShows,latestEpisodes", continueListening: false, smartLists: false)
        == [.yourShows, .latestEpisodes])
  }

  @Test("a stale or unknown stored order still draws every section")
  func staleOrderNeverHides() {
    #expect(
      Set(drawn(hidden: "removedSection", order: "removedSection,yourShows"))
        == Set(PodcastsRootSection.allCases))
  }

  @Test("every section has a title matching its heading")
  func titlesMatchHeadings() {
    #expect(
      PodcastsViewPresentation.rootSectionTitle(.continueListening)
        == HomeCopy.continueListeningTitle)
    #expect(
      PodcastsViewPresentation.rootSectionTitle(.latestEpisodes) == HomeCopy.latestEpisodesTitle)
    #expect(
      PodcastsViewPresentation.rootSectionTitle(.yourShows)
        == PodcastsViewPresentation.showsSectionTitle)
  }

  @Test("the Smart Lists section's title is its heading")
  func smartListsTitle() {
    #expect(
      PodcastsViewPresentation.rootSectionTitle(.smartLists) == SmartListsPresentation.sectionTitle)
  }

  @Test("hiding every section does not turn the root toolbar into anything but Add Podcast")
  func rootToolbarIsUnchanged() {
    #expect(PodcastsViewPresentation.rootToolbarItems == ["Add Podcast"])
  }
}

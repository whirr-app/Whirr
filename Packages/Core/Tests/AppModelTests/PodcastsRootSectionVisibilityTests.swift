import Testing

@testable import AppModel

@Suite("Podcasts root section visibility")
struct PodcastsRootSectionVisibilityTests {

  @Test("the built-in order is the layout's current order")
  func builtInOrder() {
    #expect(PodcastsRootSection.allCases == [.continueListening, .latestEpisodes, .smartLists, .yourShows])
  }

  @Test("nothing is hidden by default")
  func emptyStoreHidesNothing() {
    #expect(PodcastsRootSectionVisibility.hidden(in: "").isEmpty)
    for section in PodcastsRootSection.allCases {
      #expect(PodcastsRootSectionVisibility.isVisible(section, in: ""))
    }
  }

  @Test("hidden sections round-trip through the stored string in declaration order")
  func hiddenSectionsRoundTrip() {
    let stored = PodcastsRootSectionVisibility.stored(hidden: [.yourShows, .continueListening])
    #expect(stored == "continueListening,yourShows")
    #expect(
      PodcastsRootSectionVisibility.hidden(in: stored) == [.continueListening, .yourShows])
  }

  @Test("unknown and empty tokens are ignored rather than hiding or corrupting anything")
  func unknownTokensAreIgnored() {
    let hidden = PodcastsRootSectionVisibility.hidden(
      in: ",latestEpisodes,,junk, yourShows ")
    #expect(hidden == [.latestEpisodes, .yourShows])
  }

  @Test("toggling a section off then on returns to the original preference")
  func togglingIsReversible() {
    let hiddenOnce = PodcastsRootSectionVisibility.updating(
      "", section: .latestEpisodes, isVisible: false)
    #expect(PodcastsRootSectionVisibility.isVisible(.latestEpisodes, in: hiddenOnce) == false)
    #expect(PodcastsRootSectionVisibility.isVisible(.yourShows, in: hiddenOnce))
    #expect(
      PodcastsRootSectionVisibility.updating(
        hiddenOnce, section: .latestEpisodes, isVisible: true) == "")
  }

  @Test("hiding the same section twice does not duplicate it")
  func hidingIsIdempotent() {
    var stored = PodcastsRootSectionVisibility.updating(
      "", section: .yourShows, isVisible: false)
    stored = PodcastsRootSectionVisibility.updating(stored, section: .yourShows, isVisible: false)
    #expect(stored == "yourShows")
  }

  @Test("Smart Lists can be hidden on its own")
  func smartListsHidesOnItsOwn() {
    let stored = PodcastsRootSectionVisibility.updating(
      "", section: .smartLists, isVisible: false)
    #expect(stored == "smartLists")
    #expect(PodcastsRootSectionVisibility.isVisible(.smartLists, in: stored) == false)
    #expect(PodcastsRootSectionVisibility.isVisible(.yourShows, in: stored))
  }

  @Test("the Podcasts keys are distinct from Home's")
  func keysAreDistinct() {
    #expect(PodcastsRootSectionVisibility.storageKey == "podcasts.hiddenSections")
    #expect(PodcastsRootSectionOrder.storageKey == "podcasts.sectionOrder")
    #expect(PodcastsRootSectionVisibility.storageKey != HomeSectionVisibility.storageKey)
    #expect(PodcastsRootSectionOrder.storageKey != HomeSectionOrder.storageKey)
  }
}

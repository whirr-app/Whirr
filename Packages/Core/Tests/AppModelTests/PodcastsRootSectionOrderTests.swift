import Foundation
import Testing

@testable import AppModel

@Suite("Podcasts root section order")
struct PodcastsRootSectionOrderTests {

  @Test("an empty preference is the built-in order")
  func emptyStoreIsTheDefaultOrder() {
    #expect(PodcastsRootSectionOrder.ordered(in: "") == PodcastsRootSection.allCases)
  }

  @Test("a stored order round-trips")
  func storedOrderRoundTrips() {
    let order: [PodcastsRootSection] = [
      .yourShows, .smartLists, .continueListening, .latestEpisodes,
    ]
    let stored = PodcastsRootSectionOrder.stored(order)
    #expect(PodcastsRootSectionOrder.ordered(in: stored) == order)
  }

  @Test("sections missing from a stored order are appended in built-in order, never dropped")
  func missingSectionsAreAppended() {
    #expect(
      PodcastsRootSectionOrder.ordered(in: "yourShows")
        == [.yourShows, .continueListening, .latestEpisodes, .smartLists])
    #expect(
      PodcastsRootSectionOrder.ordered(in: "latestEpisodes,yourShows")
        == [.latestEpisodes, .yourShows, .continueListening, .smartLists])
  }

  @Test("unknown and duplicate tokens are dropped rather than corrupting the order")
  func junkTokensAreDropped() {
    #expect(
      PodcastsRootSectionOrder.ordered(in: "yourShows,junk,yourShows, latestEpisodes ")
        == [.yourShows, .latestEpisodes, .continueListening, .smartLists])
  }

  @Test("a stale or junk preference never hides a section")
  func everySectionAlwaysPresent() {
    for stored in ["", "junk", "yourShows", ",,", "continueListening,continueListening"] {
      #expect(
        Set(PodcastsRootSectionOrder.ordered(in: stored)) == Set(PodcastsRootSection.allCases))
    }
  }

  @Test("an order stored before Smart Lists existed shows it last, never hides it")
  func anOrderFromBeforeSmartListsAppendsIt() {
    let stored = PodcastsRootSectionOrder.stored([.yourShows, .continueListening, .latestEpisodes])
    #expect(
      PodcastsRootSectionOrder.ordered(in: stored)
        == [.yourShows, .continueListening, .latestEpisodes, .smartLists])
  }

  @Test("a drag moves one section and leaves the others in place")
  func movingRewritesTheOrder() {
    let stored = PodcastsRootSectionOrder.moving("", fromOffsets: IndexSet(integer: 3), toOffset: 0)
    #expect(
      PodcastsRootSectionOrder.ordered(in: stored)
        == [.yourShows, .continueListening, .latestEpisodes, .smartLists])
  }

  @Test("a move is expressed against the current stored order, not the built-in one")
  func movingComposesWithAPreviousMove() {
    let once = PodcastsRootSectionOrder.moving("", fromOffsets: IndexSet(integer: 3), toOffset: 0)
    let twice = PodcastsRootSectionOrder.moving(once, fromOffsets: IndexSet(integer: 0), toOffset: 4)
    #expect(
      PodcastsRootSectionOrder.ordered(in: twice)
        == [.continueListening, .latestEpisodes, .smartLists, .yourShows])
  }

  @Test("a section steps one place without a drag")
  func steppingOnePlace() {
    let stored = PodcastsRootSectionOrder.stored(PodcastsRootSection.allCases)
    let up = PodcastsRootSectionOrder.stepping(stored, section: .latestEpisodes, by: -1)
    #expect(PodcastsRootSectionOrder.ordered(in: up).first == .latestEpisodes)
    let down = PodcastsRootSectionOrder.stepping(stored, section: .latestEpisodes, by: 1)
    #expect(
      PodcastsRootSectionOrder.ordered(in: down)
        == [.continueListening, .smartLists, .latestEpisodes, .yourShows])
  }

  @Test("stepping past either end is a no-op rather than a wrap")
  func steppingPastTheEndsDoesNothing() {
    let order = PodcastsRootSection.allCases
    let stored = PodcastsRootSectionOrder.stored(order)
    #expect(
      PodcastsRootSectionOrder.ordered(
        in: PodcastsRootSectionOrder.stepping(stored, section: order[0], by: -1)) == order)
    #expect(
      PodcastsRootSectionOrder.ordered(
        in: PodcastsRootSectionOrder.stepping(stored, section: order[order.count - 1], by: 1))
        == order)
  }

  @Test("whether a section can step is answered from the same order the rows are drawn from")
  func canStepMatchesThePosition() {
    let order = PodcastsRootSection.allCases
    let stored = PodcastsRootSectionOrder.stored(order)
    #expect(PodcastsRootSectionOrder.canStep(stored, section: order[0], by: -1) == false)
    #expect(PodcastsRootSectionOrder.canStep(stored, section: order[0], by: 1))
    #expect(PodcastsRootSectionOrder.canStep(stored, section: order[order.count - 1], by: 1) == false)
  }

  @Test("sorting a filtered set follows the reader's order")
  func sortedFollowsStoredOrder() {
    let stored = PodcastsRootSectionOrder.stored([.yourShows, .latestEpisodes, .continueListening])
    #expect(
      PodcastsRootSectionOrder.sorted([.continueListening, .yourShows], in: stored)
        == [.yourShows, .continueListening])
  }
}

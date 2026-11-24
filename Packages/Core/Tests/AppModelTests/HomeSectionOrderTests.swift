import Foundation
import Testing

@testable import AppModel

@Suite("Home section order")
struct HomeSectionOrderTests {

  @Test("an empty preference is the built-in shelf order")
  func emptyStoreIsTheDefaultOrder() {
    #expect(HomeSectionOrder.ordered(in: "") == HomeMoreSection.allCases)
  }

  @Test("a stored order round-trips")
  func storedOrderRoundTrips() {
    let order: [HomeMoreSection] = [
      .downloaded, .newEpisodes, .continueListening, .continueReading, .continueSeries, .recentlyAdded,
      .savedForLater, .listeningStats, .smartLists,
    ]
    let stored = HomeSectionOrder.stored(order)
    #expect(HomeSectionOrder.ordered(in: stored) == order)
  }

  /// A section added in a later release is absent from an existing device's stored order. It must
  /// still appear, appended in its built-in position relative to the other unknown-to-the-store
  /// sections, rather than silently vanishing from Home.
  @Test("sections missing from a stored order are appended in built-in order")
  func missingSectionsAreAppended() {
    let stored = HomeSectionOrder.stored([.downloaded, .continueListening])
    #expect(
      HomeSectionOrder.ordered(in: stored)
        == [
          .downloaded, .continueListening, .continueReading, .continueSeries, .newEpisodes,
          .recentlyAdded,
          .savedForLater, .listeningStats, .smartLists,
        ])
  }

  @Test("unknown and duplicate tokens are dropped rather than corrupting the order")
  func junkTokensAreDropped() {
    let ordered = HomeSectionOrder.ordered(in: "downloaded,notASection,downloaded, recentlyAdded ")
    #expect(
      ordered
        == [
          .downloaded, .recentlyAdded, .continueListening, .continueReading, .continueSeries,
          .newEpisodes,
          .savedForLater, .listeningStats, .smartLists,
        ])
  }

  @Test("a pre-feature stored order appends Saved for Later last")
  func preFeatureOrderAppendsSavedForLater() {
    let stored =
      "continueListening,continueReading,continueSeries,newEpisodes,recentlyAdded,downloaded"
    #expect(
      HomeSectionOrder.ordered(in: stored)
        == [
          .continueListening, .continueReading, .continueSeries, .newEpisodes, .recentlyAdded,
          .downloaded, .savedForLater, .listeningStats, .smartLists,
        ])
  }

  @Test("a stored order from before Listening Stats appends it last")
  func preFeatureOrderAppendsListeningStats() {
    let stored =
      "continueListening,continueReading,continueSeries,newEpisodes,recentlyAdded,downloaded,savedForLater"
    #expect(HomeSectionOrder.ordered(in: stored).suffix(2) == [.listeningStats, .smartLists])
  }

  @Test("a stored order from before Smart Lists appends it last")
  func preFeatureOrderAppendsSmartLists() {
    let stored =
      "listeningStats,continueListening,continueReading,continueSeries,newEpisodes,recentlyAdded,downloaded,savedForLater"
    #expect(HomeSectionOrder.ordered(in: stored).last == .smartLists)
    #expect(HomeCopy.sectionTitle(.smartLists) == "Smart Lists")
  }

  @Test("a drag moves one section and leaves the others in place")
  func movingRewritesTheOrder() {
    // Drag Downloaded (index 5) to the top.
    let stored = HomeSectionOrder.moving("", fromOffsets: IndexSet(integer: 5), toOffset: 0)
    #expect(
      HomeSectionOrder.ordered(in: stored)
        == [
          .downloaded, .continueListening, .continueReading, .continueSeries, .newEpisodes,
          .recentlyAdded,
          .savedForLater, .listeningStats, .smartLists,
        ])
  }

  @Test("a move is expressed against the current stored order, not the built-in one")
  func movingComposesWithAPreviousMove() {
    let once = HomeSectionOrder.moving("", fromOffsets: IndexSet(integer: 5), toOffset: 0)
    // Now drag what is currently second (Continue Listening) to the end.
    let twice = HomeSectionOrder.moving(once, fromOffsets: IndexSet(integer: 1), toOffset: 6)
    #expect(
      HomeSectionOrder.ordered(in: twice)
        == [
          .downloaded, .continueReading, .continueSeries, .newEpisodes, .recentlyAdded,
          .continueListening,
          .savedForLater, .listeningStats, .smartLists,
        ])
  }

  /// WCAG 2.5.7 (Dragging Movements): a drag handle is unusable with a head pointer, a
  /// switch-adapted mouse, or an unsteady hand, and edit mode only replaces one drag with another.
  /// Stepping a section one place is the single-pointer form of the same operation, so the
  /// arithmetic lives here where it can be tested rather than in a menu closure.
  @Test("a section steps one place without a drag")
  func steppingOnePlace() {
    let order = HomeMoreSection.allCases
    let stored = HomeSectionOrder.stored(order)
    let second = order[1]

    let up = HomeSectionOrder.ordered(in: HomeSectionOrder.stepping(stored, section: second, by: -1))
    #expect(up.firstIndex(of: second) == 0)

    let down = HomeSectionOrder.ordered(
      in: HomeSectionOrder.stepping(stored, section: second, by: 1))
    #expect(down.firstIndex(of: second) == 2)
  }

  @Test("stepping past either end is a no-op rather than a wrap")
  func steppingPastTheEndsDoesNothing() {
    let order = HomeMoreSection.allCases
    let stored = HomeSectionOrder.stored(order)

    #expect(
      HomeSectionOrder.ordered(in: HomeSectionOrder.stepping(stored, section: order[0], by: -1))
        == order)
    #expect(
      HomeSectionOrder.ordered(
        in: HomeSectionOrder.stepping(stored, section: order[order.count - 1], by: 1)) == order)
  }

  @Test("whether a section can step is answered from the same order the rows are drawn from")
  func canStepMatchesThePosition() {
    let order = HomeMoreSection.allCases
    let stored = HomeSectionOrder.stored(order)

    #expect(HomeSectionOrder.canStep(stored, section: order[0], by: -1) == false)
    #expect(HomeSectionOrder.canStep(stored, section: order[0], by: 1))
    #expect(HomeSectionOrder.canStep(stored, section: order[order.count - 1], by: 1) == false)
  }
}

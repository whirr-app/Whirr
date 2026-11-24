import Testing

@testable import Whirr

/// The "renders on iPhone and iPad size classes" requirement is proven here, at the test level.
/// Nothing boots a simulator or inspects visuals.
@Suite("Search UI harness configuration")
struct SearchUIHarnessConfigurationTests {
  @Test func everyServerlessScenarioIsRepresented() {
    #expect(Set(UIHarness.SearchScenario.allCases) == Set([.allKinds, .partial, .empty]))
  }

  @Test func representativePhoneAndPadConfigurationsAreRepresented() {
    #expect(UIHarness.SearchHarnessFormFactor.compactPhone.maximumContentWidth == 430)
    #expect(UIHarness.SearchHarnessFormFactor.compactPhone.horizontalSizeClass == .compact)
    #expect(UIHarness.SearchHarnessFormFactor.regularPad.maximumContentWidth == 1_180)
    #expect(UIHarness.SearchHarnessFormFactor.regularPad.horizontalSizeClass == .regular)
  }

  @Test func allKindsScenarioCoversEveryResultKindIncludingAnEbookCategoryBookRow() {
    let itemKinds = Set(HarnessSearchFixtures.itemRows.map(\.kind))
    let episodeKinds = Set(HarnessSearchFixtures.episodeRows.map(\.kind))
    let matchKinds = Set(HarnessSearchFixtures.authorSeriesMatches.map(\.kind))

    #expect(itemKinds.contains(.book))
    #expect(itemKinds.contains(.podcast))
    #expect(episodeKinds == [.episode])
    #expect(matchKinds == [.author, .series])
    #expect(HarnessSearchFixtures.itemRows.contains { $0.kind == .book && $0.mediaCategory == .ebook })
    #expect(
      HarnessSearchFixtures.itemRows.contains { $0.kind == .book && $0.mediaCategory == .audiobook })
  }

  @Test func rowTapsResignTheSearchFieldBeforeNavigating() {
    // A result tap must lower the field before pushing a destination, so its keyboard and inset do
    // not stay attached to the pushed stack. The push waits a turn for that write to commit.
    // Otherwise the field leaves the hierarchy before the resignation reaches it, and the keyboard
    // is stranded over the destination.
    #expect(SearchViewPresentation.resignsFocusBeforeNavigating)
    #expect(SearchViewPresentation.navigationWaitsForFocusResignation)
  }
}

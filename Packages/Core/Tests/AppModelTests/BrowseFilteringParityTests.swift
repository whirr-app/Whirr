import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing

@testable import AppModel

/// The pin behind Search/Library filter parity.
///
/// One `BrowseFilterMenu`, generic over `BrowseFiltering`, keeps the two screens' rows from
/// diverging. This suite drives both models through the same protocol calls and requires the same
/// `BrowseFilters`, so a tap means the same on both. It asserts nothing about what each does with
/// the change (Library re-subscribes an observation, Search re-runs its query).
@Suite struct BrowseFilteringParityTests {

  /// Each step is one row of the funnel, in the order the menu declares them.
  private static let steps: [(name: String, apply: @MainActor (any BrowseFiltering) -> Void)] = [
    ("select audiobooks", { $0.setMediaCategory(.audiobook, isOn: true) }),
    ("add ebooks", { $0.setMediaCategory(.ebook, isOn: true) }),
    ("downloaded only", { $0.updateDownloadedOnly(true) }),
    ("unplayed", { $0.updatePlayback(.unfinished) }),
    ("in progress", { $0.updatePlayback(.inProgress) }),
    ("drop audiobooks", { $0.setMediaCategory(.audiobook, isOn: false) }),
    ("finished", { $0.updatePlayback(.finished) }),
    ("drop the last category", { $0.setMediaCategory(.ebook, isOn: false) }),
    ("downloaded off", { $0.updateDownloadedOnly(false) }),
    ("clear all", { $0.clearFilters() }),
  ]

  @MainActor
  @Test("both screens' models reach the same filter from the same sequence of funnel taps")
  func bothModelsAgreeStepForStep() {
    let library: any BrowseFiltering = LibraryBrowseModel(
      library: FakeLibraryReading(), sync: FakeSyncCoordinating(),
      defaults: FakeBrowseFilterDefaults())
    // Nothing here searches. The assertions are about the filter each tap produces, so the read
    // boundary only has to exist.
    let search: any BrowseFiltering = SearchModel(
      library: FakeLibraryReading(), searchReading: NoOpSearchReading(),
      sync: FakeSyncCoordinating(), clock: FakeSearchClock(),
      defaults: FakeBrowseFilterDefaults())

    #expect(library.filters == search.filters, "the two models start from different filters")

    for step in Self.steps {
      step.apply(library)
      step.apply(search)
      #expect(
        library.filters == search.filters,
        "after \"\(step.name)\": Library \(library.filters) vs Search \(search.filters)")
      #expect(
        ItemMediaCategory.allCases.allSatisfy {
          library.isMediaCategorySelected($0) == search.isMediaCategorySelected($0)
        },
        "after \"\(step.name)\": the two disagree about which categories are selected")
    }

    #expect(library.filters == .unfiltered)
  }
}

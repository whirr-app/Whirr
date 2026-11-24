import Foundation
import Persistence
import Testing

@testable import AppModel

/// The Library filter is a device preference stored as one stable string, like
/// `HomeSectionVisibility` (not account state, no schema change). A corrupt or unrecognised value
/// must degrade to "unfiltered", not trap or strand the reader behind an unseen filter.
@Suite struct BrowseFilterStorageTests {

  // MARK: - The pure transforms

  @Test("the unfiltered value encodes to the empty string")
  func unfilteredEncodesToTheEmptyString() {
    #expect(BrowseFilterStorage.stored(filters: .unfiltered).isEmpty)
  }

  @Test("every representable combination round-trips exactly")
  func everyCombinationRoundTrips() {
    for categories in Self.allCategoryChoices {
      for downloadedOnly in [false, true] {
        for playback in PlaybackFilter.allCases {
          let filters = BrowseFilters(
            categories: categories, downloadedOnly: downloadedOnly, playback: playback)
          let decoded = BrowseFilterStorage.filters(in: BrowseFilterStorage.stored(filters: filters))
          #expect(decoded == filters, "round trip lost \(BrowseFilterStorage.stored(filters: filters))")
        }
      }
    }
  }

  @Test("categories are emitted in ItemMediaCategory.allCases order, whatever the set's own order")
  func categoriesAreEmittedInAllCasesOrder() {
    let one = BrowseFilterStorage.stored(filters: BrowseFilters(categories: [.ebook, .audiobook]))
    let other = BrowseFilterStorage.stored(filters: BrowseFilters(categories: [.audiobook, .ebook]))

    #expect(one == other)
    let audiobookIndex = try? #require(one.range(of: "audiobook")).lowerBound
    let ebookIndex = try? #require(one.range(of: "ebook")).lowerBound
    #expect(audiobookIndex != nil && ebookIndex != nil)
    if let audiobookIndex, let ebookIndex { #expect(audiobookIndex < ebookIndex) }
  }

  @Test("equal filters always encode to the identical string, whatever order they were built in")
  func equalFiltersAlwaysEncodeIdentically() {
    // The `HomeSectionVisibility.stored(hidden:)` rule: the encoder emits a fixed field order and
    // a fixed category order, so the stored value depends on the filter alone, not on the order
    // the reader flipped the toggles in.
    #expect(
      BrowseFilterStorage.stored(
        filters: BrowseFilters(categories: [.podcast, .ebook], downloadedOnly: true, playback: .finished))
        == BrowseFilterStorage.stored(
          filters: BrowseFilters(categories: [.ebook, .podcast], downloadedOnly: true, playback: .finished)))

    // And a value reached by decoding is indistinguishable from one built directly.
    let direct = BrowseFilters(categories: [.audiobook], playback: .unfinished)
    let decoded = BrowseFilterStorage.filters(in: BrowseFilterStorage.stored(filters: direct))
    #expect(BrowseFilterStorage.stored(filters: decoded) == BrowseFilterStorage.stored(filters: direct))
  }

  // MARK: - Degrading, never trapping

  @Test("a corrupt or unrecognised stored string decodes to unfiltered without trapping")
  func corruptStoredStringDecodesToUnfiltered() {
    for stored in ["", "  ", ";;;", "=", "garbage", "nonsense=yes", "🙂", "categories", "playback"] {
      #expect(BrowseFilterStorage.filters(in: stored) == .unfiltered, "\(stored) should be inert")
    }
  }

  @Test("unknown categories are ignored while the recognised ones survive")
  func unknownCategoriesAreIgnored() {
    let decoded = BrowseFilterStorage.filters(in: "categories=audiobook,graphicnovel")
    #expect(decoded == BrowseFilters(categories: [.audiobook]))
  }

  @Test("a category field naming only unknown values leaves no category constraint")
  func onlyUnknownCategoriesLeavesNoConstraint() {
    #expect(BrowseFilterStorage.filters(in: "categories=graphicnovel") == .unfiltered)
  }

  @Test("an unknown playback raw value falls back to any")
  func unknownPlaybackFallsBackToAny() {
    #expect(BrowseFilterStorage.filters(in: "playback=abandoned") == .unfiltered)
    #expect(
      BrowseFilterStorage.filters(in: "downloaded=1;playback=abandoned")
        == BrowseFilters(downloadedOnly: true))
  }

  // MARK: - The UserDefaults surface

  @Test("saving the unfiltered value removes the key rather than storing an empty one")
  func savingUnfilteredRemovesTheKey() {
    let defaults = Self.freshDefaults()

    BrowseFilterStorage.save(BrowseFilters(downloadedOnly: true), for: .library, to: defaults)
    #expect(defaults.filterString(forKey: BrowseFilterStorage.Screen.library.storageKey) != nil)

    BrowseFilterStorage.save(.unfiltered, for: .library, to: defaults)
    #expect(defaults.isEmpty)
  }

  @Test("a fresh defaults suite loads the unfiltered value")
  func freshSuiteLoadsUnfiltered() {
    let defaults = Self.freshDefaults()
    #expect(BrowseFilterStorage.load(.library, from: defaults) == .unfiltered)
  }

  @Test("a saved filter loads back through the injected suite")
  func savedFilterLoadsBack() {
    let defaults = Self.freshDefaults()
    let filters = BrowseFilters(categories: [.podcast], downloadedOnly: true, playback: .unfinished)

    BrowseFilterStorage.save(filters, for: .library, to: defaults)

    #expect(BrowseFilterStorage.load(.library, from: defaults) == filters)
  }

  /// The two screens run the same control over the same type, so they must not share a stored
  /// value: a Library narrowed to Downloaded weeks ago must not silently narrow the next search.
  @Test("each screen stores its filter under its own key, and neither reads the other's")
  func screensDoNotShareAStoredFilter() {
    let defaults = Self.freshDefaults()
    let libraryFilters = BrowseFilters(categories: [.audiobook], downloadedOnly: true)
    let searchFilters = BrowseFilters(playback: .finished)

    BrowseFilterStorage.save(libraryFilters, for: .library, to: defaults)
    BrowseFilterStorage.save(searchFilters, for: .search, to: defaults)

    #expect(BrowseFilterStorage.load(.library, from: defaults) == libraryFilters)
    #expect(BrowseFilterStorage.load(.search, from: defaults) == searchFilters)

    BrowseFilterStorage.save(.unfiltered, for: .search, to: defaults)
    #expect(BrowseFilterStorage.load(.library, from: defaults) == libraryFilters)
    #expect(BrowseFilterStorage.load(.search, from: defaults) == .unfiltered)
  }

  /// The Library's key already has stored values on real devices, so changing it would silently
  /// unfilter every existing install.
  @Test("the Library's storage key is unchanged, and Search's is distinct from it")
  func libraryKeyIsUnchanged() {
    #expect(BrowseFilterStorage.Screen.library.storageKey == "library.filters")
    #expect(BrowseFilterStorage.Screen.search.storageKey != BrowseFilterStorage.Screen.library.storageKey)
  }

  // MARK: - Fixtures

  private static let allCategoryChoices: [Set<ItemMediaCategory>?] = [
    nil, [.audiobook], [.podcast], [.ebook], [.audiobook, .podcast],
    [.audiobook, .podcast, .ebook],
  ]

  /// In-memory, so nothing here touches the real app's preferences or the preferences daemon.
  private static func freshDefaults() -> FakeBrowseFilterDefaults { FakeBrowseFilterDefaults() }
}

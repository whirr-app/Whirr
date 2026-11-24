import Foundation
import Testing

@testable import Persistence

/// The composite filter value the Library's read boundary and model both carry. It exists so a
/// third Library-shaped filter vocabulary is never invented on top of `SearchFilters` and
/// `PodcastEpisodeFilter`.
@Suite struct BrowseFiltersTests {

  @Test("the unfiltered value is inactive and counts no dimensions")
  func unfilteredIsInactive() {
    #expect(BrowseFilters.unfiltered.isActive == false)
    #expect(BrowseFilters.unfiltered.activeCount == 0)
    #expect(BrowseFilters.unfiltered.categories == nil)
    #expect(BrowseFilters.unfiltered.downloadedOnly == false)
    #expect(BrowseFilters.unfiltered.playback == .any)
  }

  @Test("each dimension alone flips isActive")
  func eachDimensionAloneIsActive() {
    #expect(BrowseFilters(categories: [.podcast]).isActive)
    #expect(BrowseFilters(downloadedOnly: true).isActive)
    #expect(BrowseFilters(playback: .unfinished).isActive)
    #expect(BrowseFilters(playback: .finished).isActive)
  }

  @Test("activeCount reports the number of engaged dimensions, not the number of categories")
  func activeCountReportsEngagedDimensions() {
    #expect(BrowseFilters(categories: [.podcast]).activeCount == 1)
    #expect(BrowseFilters(categories: [.podcast, .ebook]).activeCount == 1)
    #expect(BrowseFilters(downloadedOnly: true, playback: .finished).activeCount == 2)
    #expect(
      BrowseFilters(categories: [.audiobook], downloadedOnly: true, playback: .unfinished)
        .activeCount == 3)
  }

  @Test("construction canonicalizes an empty category set to no constraint")
  func emptyCategorySetIsCanonicalizedToNil() {
    let empty = BrowseFilters(categories: [])
    #expect(empty.categories == nil)
    #expect(empty.isActive == false)
  }

  @Test("equality and hashing therefore treat nil and an empty set as the same value")
  func nilAndEmptyCategoriesAreTheSameValue() {
    let fromEmpty = BrowseFilters(categories: [])
    let fromNil = BrowseFilters(categories: nil)

    #expect(fromEmpty == fromNil)
    #expect(fromEmpty == .unfiltered)
    #expect(fromEmpty.hashValue == fromNil.hashValue)
    #expect(Set([fromEmpty, fromNil, .unfiltered]).count == 1)
  }

  @Test("category set order does not affect equality or hashing")
  func categorySetOrderDoesNotAffectEquality() {
    let one = BrowseFilters(categories: [.podcast, .ebook])
    let other = BrowseFilters(categories: [.ebook, .podcast])

    #expect(one == other)
    #expect(one.hashValue == other.hashValue)
  }

  @Test("a differing dimension makes two values unequal")
  func differingDimensionsAreUnequal() {
    #expect(BrowseFilters(playback: .unfinished) != BrowseFilters(playback: .finished))
    #expect(BrowseFilters(downloadedOnly: true) != BrowseFilters.unfiltered)
    #expect(BrowseFilters(categories: [.podcast]) != BrowseFilters(categories: [.ebook]))
  }

  /// The case order is not an implementation detail: `BrowseFilterMenu` renders `allCases`, so
  /// this array is the order of the rows in the funnel. `inProgress` sits between the two states it
  /// separates, which is also the order a reader moves through them.
  @Test("PlaybackFilter's raw values and order are the stable persisted, rendered sequence")
  func playbackFilterRawValuesAreStable() {
    #expect(PlaybackFilter.any.rawValue == "any")
    #expect(PlaybackFilter.unfinished.rawValue == "unfinished")
    #expect(PlaybackFilter.inProgress.rawValue == "inProgress")
    #expect(PlaybackFilter.finished.rawValue == "finished")
    #expect(Array(PlaybackFilter.allCases) == [.any, .unfinished, .inProgress, .finished])
  }
}

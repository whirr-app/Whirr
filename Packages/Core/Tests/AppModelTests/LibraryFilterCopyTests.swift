import Foundation
import Persistence
import Testing

@testable import AppModel

/// The Library funnel's copy, table-driven over every reachable active combination (4 media
/// choices × 2 download × 3 playback, minus unfiltered). Filters persist across a cold launch, so
/// a reader returning weeks later must be told they are filtered, never that the library is empty.
@Suite struct LibraryFilterCopyTests {

  /// The 23 reachable active combinations, plus the unfiltered one for the contrast assertions.
  private static let allCombinations: [BrowseFilters] = {
    var combinations: [BrowseFilters] = []
    for media in MediaFilter.allCases {
      for downloadedOnly in [false, true] {
        for playback in PlaybackFilter.allCases {
          combinations.append(
            BrowseFilters(
              categories: media.browseCategories, downloadedOnly: downloadedOnly, playback: playback))
        }
      }
    }
    return combinations
  }()

  private static var activeCombinations: [BrowseFilters] {
    allCombinations.filter(\.isActive)
  }

  @Test("the table covers exactly the 31 reachable active combinations")
  func theTableCoversEveryReachableActiveCombination() {
    #expect(Self.allCombinations.count == 32)
    #expect(Self.activeCombinations.count == 31)
  }

  @Test("the active summary names every engaged dimension and nothing else")
  func activeSummaryNamesEveryEngagedDimension() {
    for filters in Self.activeCombinations {
      let summary = LibraryFilterCopy.activeSummary(for: filters)
      let media = MediaFilter(browseCategories: filters.categories)

      if filters.categories != nil {
        #expect(
          summary.contains(MediaFilterCopy.label(for: media)),
          "\(summary) should name the media kind \(media)")
      }
      #expect(
        summary.contains(LibraryFilterCopy.downloadedTitle) == filters.downloadedOnly,
        "\(summary) names Downloaded only when it is engaged")
      if filters.playback != .any {
        #expect(
          summary.contains(LibraryFilterCopy.playbackLabel(for: filters.playback)),
          "\(summary) should name the playback state")
      }
    }
  }

  @Test("the unfiltered summary claims no dimensions but still names the control")
  func unfilteredSummaryNamesTheControlOnly() {
    let summary = LibraryFilterCopy.activeSummary(for: .unfiltered)

    #expect(summary.isEmpty == false)
    #expect(summary.contains(LibraryFilterCopy.downloadedTitle) == false)
    #expect(summary.contains(LibraryFilterCopy.playbackLabel(for: .unfinished)) == false)
    #expect(summary != LibraryFilterCopy.activeSummary(for: BrowseFilters(downloadedOnly: true)))
  }

  @Test("the filtered-empty copy blames the filter, never an empty library")
  func filteredEmptyCopyBlamesTheFilter() {
    for filters in Self.activeCombinations {
      let title = LibraryFilterCopy.filteredEmptyTitle(for: filters)
      let message = LibraryFilterCopy.filteredEmptyMessage(for: filters)

      #expect(title.isEmpty == false)
      #expect(message.localizedCaseInsensitiveContains("filter"), "\(message) must identify the cause")
      #expect(
        message.localizedCaseInsensitiveContains("library is empty") == false,
        "\(message) must never claim the library is empty")
    }
  }

  @Test("the filtered-empty message names the engaged dimensions so the reader knows what to undo")
  func filteredEmptyMessageNamesTheEngagedDimensions() {
    let filters = BrowseFilters(categories: [.podcast], downloadedOnly: true, playback: .finished)
    let message = LibraryFilterCopy.filteredEmptyMessage(for: filters)

    #expect(message.contains(MediaFilterCopy.label(for: .podcasts)))
    #expect(message.contains(LibraryFilterCopy.downloadedTitle))
    #expect(message.contains(LibraryFilterCopy.playbackLabel(for: .finished)))
  }

  @Test("the active summary names every selected media kind")
  func activeSummaryNamesMultipleMediaKinds() {
    let summary = LibraryFilterCopy.activeSummary(
      for: BrowseFilters(categories: [.audiobook, .podcast], downloadedOnly: true))

    #expect(summary.contains(MediaFilterCopy.label(for: .audiobooks)))
    #expect(summary.contains(MediaFilterCopy.label(for: .podcasts)))
    #expect(summary.contains(LibraryFilterCopy.downloadedTitle))
    #expect(summary.contains(MediaFilterCopy.label(for: .all)) == false)
  }

  @Test("the reset labels and the funnel's dimension labels are all non-empty and distinct")
  func labelsAreNonEmptyAndDistinct() {
    let labels =
      [
        LibraryFilterCopy.applyFiltersLabel,
        LibraryFilterCopy.clearFiltersLabel,
        LibraryFilterCopy.clearAllFiltersLabel,
        LibraryFilterCopy.downloadedTitle,
        LibraryFilterCopy.playbackTitle,
        LibraryFilterCopy.filterTitle,
      ] + PlaybackFilter.allCases.map(LibraryFilterCopy.playbackLabel(for:))

    for label in labels { #expect(label.isEmpty == false) }
    #expect(Set(labels).count == labels.count)
  }

  /// The code name stays `unfinished` while the label is "Unplayed"; since `inProgress` covers the
  /// part-listened items, the two mean the same thing.
  @Test("the playback labels read Any, Unplayed, In Progress and Finished")
  func playbackLabelsUseTheOwnersWording() {
    #expect(LibraryFilterCopy.playbackLabel(for: .unfinished) == "Unplayed")
    #expect(LibraryFilterCopy.playbackLabel(for: .inProgress) == "In Progress")
    #expect(LibraryFilterCopy.playbackLabel(for: .finished) == "Finished")
    #expect(LibraryFilterCopy.playbackLabel(for: .any) == "Any")
  }

  /// The playback rows sit in a submenu so the funnel fits above the fold, which hides the
  /// checkmark. The collapsed row has to name the engaged state instead, and must not name "Any",
  /// which would claim a filter that is not on.
  @Test("the collapsed playback row names the engaged state and only the engaged state")
  func playbackMenuLabelNamesTheEngagedState() {
    #expect(LibraryFilterCopy.playbackMenuLabel(for: .any) == LibraryFilterCopy.playbackTitle)
    for playback in PlaybackFilter.allCases where playback != .any {
      let label = LibraryFilterCopy.playbackMenuLabel(for: playback)
      #expect(label.contains(LibraryFilterCopy.playbackTitle))
      #expect(label.contains(LibraryFilterCopy.playbackLabel(for: playback)))
      #expect(label != LibraryFilterCopy.playbackTitle)
    }
  }

  @Test("media labels and nouns are delegated to MediaFilterCopy rather than restated")
  func mediaCopyIsDelegated() {
    for media in MediaFilter.allCases {
      #expect(LibraryFilterCopy.mediaLabel(for: media) == MediaFilterCopy.label(for: media))
    }
  }
}

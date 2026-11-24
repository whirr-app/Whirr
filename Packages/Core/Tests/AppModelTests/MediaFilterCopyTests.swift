import Testing

@testable import AppModel

/// The media filter's copy is shared by Home and Library, so it is named after the filter rather
/// than either tab. Its empty-state lines have to name the media type the user selected: picking
/// Podcasts on a library with none must not read "No Books Yet".
@Suite struct MediaFilterCopyTests {

  @Test("every filter has a distinct, non-empty segment label")
  func segmentLabelsAreDistinct() {
    let labels = MediaFilter.allCases.map(MediaFilterCopy.label(for:))

    #expect(Set(labels).count == MediaFilter.allCases.count)
    #expect(labels.contains(where: \.isEmpty) == false)
  }

  @Test(
    "a filtered empty state names its own media type and no other",
    arguments: MediaFilter.allCases.filter { $0 != .all })
  func filteredEmptyCopyNamesItsMediaType(filter: MediaFilter) {
    let title = MediaFilterCopy.emptyTitle(for: filter)

    #expect(title.contains(MediaFilterCopy.label(for: filter)))
    for other in MediaFilter.allCases where other != filter && other != .all {
      #expect(title.contains(MediaFilterCopy.label(for: other)) == false)
      #expect(MediaFilterCopy.pluralNoun(for: filter) != MediaFilterCopy.pluralNoun(for: other))
    }
  }

  /// The Library tab merges every library into one list, so even the unfiltered copy cannot call
  /// the contents books.
  @Test("the unfiltered empty state names no media type at all")
  func unfilteredEmptyCopyNamesNoMediaType() {
    let title = MediaFilterCopy.emptyTitle(for: .all)

    #expect(title.localizedCaseInsensitiveContains("book") == false)
    for filter in MediaFilter.allCases where filter != .all {
      #expect(title.localizedCaseInsensitiveContains(MediaFilterCopy.pluralNoun(for: filter)) == false)
    }
  }
}

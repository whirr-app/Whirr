import AppModel
import Foundation
import Persistence
import Testing

@testable import Whirr

/// One filtered projection feeds all three Library modes. A separate `observeBrowseList` per mode
/// would run the whole-library query once per mode on each sync commit, and the modes could
/// disagree about what the filter matched. The source rules for it are in
/// `Scripts/source-rules/library.toml`.
@Suite("Library shared projection")
struct LibraryProjectionCompositionTests {

  @Test("only the states that carry rows hand any to the entity modes")
  func rowStatesAreTheOnlySourceOfEntityItems() {
    let item = ItemSummary(
      serverItemId: "item-1", mediaKind: "book", title: "A Title", author: "An Author",
      durationSeconds: nil, category: .audiobook)

    #expect(LibraryBrowsePresentation.items(in: .loaded([item])) == [item])
    #expect(LibraryBrowsePresentation.items(in: .partiallySynced([item])) == [item])
    #expect(LibraryBrowsePresentation.items(in: .staleOffline([item])) == [item])
    #expect(LibraryBrowsePresentation.items(in: .loading).isEmpty)
    #expect(LibraryBrowsePresentation.items(in: .empty).isEmpty)
    #expect(LibraryBrowsePresentation.items(in: .error).isEmpty)
    #expect(LibraryBrowsePresentation.items(in: .filteredEmpty).isEmpty)
  }
}

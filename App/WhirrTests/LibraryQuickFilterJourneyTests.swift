import AppModel
import Foundation
import Persistence
import Testing

@testable import Whirr

@Suite("Library quick filter journey")
struct LibraryQuickFilterJourneyTests {

  // Treating every mode as a title search would make an author-name query pick the wrong rows or
  // miss its author. The same text must keep its mode-specific meaning.
  @Test("one query is reinterpreted by each browse mode")
  func queryScopeChangesWithMode() {
    let query = "ursula"
    let item = Self.item(id: "book", title: "A Book", author: "Adrian Tchaikovsky")
    let group = Self.group(
      kind: .author,
      entityID: "author-1",
      name: "Ursula K. Le Guin",
      libraryID: "library-1",
      items: [item])

    let titleMatches = LibraryQuickFilter.filter(items: [item], query: query)
    let authorMatches = LibraryQuickFilter.filter(groups: [group], query: query)

    #expect(titleMatches.isEmpty)
    #expect(authorMatches.map(\.entityID) == ["author-1"])
  }

  private static func item(
    id: String,
    title: String,
    author: String?,
    category: ItemMediaCategory = .audiobook
  ) -> ItemSummary {
    ItemSummary.fixture(
      serverItemId: id,
      mediaKind: category == .podcast ? "podcast" : "book",
      title: title,
      author: author,
      durationSeconds: nil,
      category: category)
  }

  private static func group(
    kind: SearchResultKind,
    entityID: String,
    name: String,
    libraryID: String,
    items: [ItemSummary]
  ) -> LibraryEntityGroup {
    LibraryEntityGroup(
      entity: AuthorSeriesEntity(
        kind: kind, entityID: entityID, name: name, libraryID: libraryID),
      items: items,
      isFiltered: false)
  }
}

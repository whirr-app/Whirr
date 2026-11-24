import Foundation
import Testing

@testable import Persistence

/// The shared search vocabulary (local search, FTS, the SyncEngine fan-out, the AppModel
/// assembler) builds rows and sections out of.
@Suite("Search result vocabulary")
struct SearchResultTests {

  private static func row(kind: SearchResultKind, entityID: String, title: String) -> SearchResultRow {
    SearchResultRow(kind: kind, entityID: entityID, title: title, libraryID: "lib1")
  }

  @Test("a section preserves row order exactly as given")
  func sectionPreservesRowOrder() {
    let rows = [
      Self.row(kind: .book, entityID: "c", title: "Third"),
      Self.row(kind: .book, entityID: "a", title: "First"),
      Self.row(kind: .book, entityID: "b", title: "Second"),
    ]

    let section = SearchSection(kind: .book, rows: rows, hasMore: false)

    #expect(section.rows.map(\.entityID) == ["c", "a", "b"])
  }

  @Test("row id is stable and unique across kinds for the same underlying entity id")
  func rowIDIsUniqueAcrossKinds() {
    let book = Self.row(kind: .book, entityID: "abc", title: "Abc the Book")
    let author = Self.row(kind: .author, entityID: "abc", title: "Abc the Author")

    #expect(book.id != author.id)
  }

  @Test("row id is stable across repeated construction of the same row")
  func rowIDIsStable() {
    let first = Self.row(kind: .episode, entityID: "ep1", title: "Episode One")
    let second = Self.row(kind: .episode, entityID: "ep1", title: "Episode One")

    #expect(first.id == second.id)
  }

  // MARK: - The name two spellings share

  /// The defect: one author filed under two spellings of their own initials is two Library rows,
  /// each holding half of the same series.
  @Test("initials spaced, unspaced, or unpunctuated are all one name")
  func initialSpellingsFoldTogether() {
    let key = AuthorSeriesEntity.normalizedName("J. N. Chaney")

    #expect(AuthorSeriesEntity.normalizedName("J.N. Chaney") == key)
    #expect(AuthorSeriesEntity.normalizedName("JN Chaney") == key)
    #expect(AuthorSeriesEntity.normalizedName("  j.n.chaney  ") == key)
  }

  @Test("case and diacritics still fold, and a hyphen no longer splits a name")
  func caseDiacriticsAndHyphens() {
    #expect(
      AuthorSeriesEntity.normalizedName("China Miéville")
        == AuthorSeriesEntity.normalizedName("china mieville"))
    #expect(
      AuthorSeriesEntity.normalizedName("Mary Robinette-Kowal")
        == AuthorSeriesEntity.normalizedName("Mary Robinette Kowal"))
  }

  @Test("two different names stay two names")
  func distinctNamesStayDistinct() {
    #expect(
      AuthorSeriesEntity.normalizedName("J. N. Chaney")
        != AuthorSeriesEntity.normalizedName("J. S. Morin"))
  }

  /// Stripping every non-alphanumeric would collapse a name made only of them to the empty key,
  /// filing unrelated entities under one row. Such a name keeps its own trimmed, folded form.
  @Test("a name with nothing alphanumeric in it is still its own key")
  func punctuationOnlyNamesDoNotCollapse() {
    #expect(AuthorSeriesEntity.normalizedName("???").isEmpty == false)
    #expect(AuthorSeriesEntity.normalizedName("???") != AuthorSeriesEntity.normalizedName("!!!"))
  }
}

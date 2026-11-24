import Foundation
import Persistence
import Testing

@testable import AppModel

/// The item detail screen's inline publication details.
@Suite struct ItemDetailAboutPresentationTests {

  /// ABS descriptions arrive as HTML. The podcast show header already strips it through
  /// `FeedHTML.plainText`; a book's blurb goes through the same door rather than rendering tags.
  @Test("a description is stripped of its markup")
  func descriptionIsStrippedOfMarkup() {
    #expect(
      ItemDetailAboutPresentation.trimmed("<p>The crew heads for <b>the Ring</b>.</p>")
        == "The crew heads for the Ring.")
  }

  @Test("blank and absent descriptions collapse to nothing rather than an empty paragraph")
  func blankDescriptionsCollapseToNothing() {
    #expect(ItemDetailAboutPresentation.trimmed(nil) == nil)
    #expect(ItemDetailAboutPresentation.trimmed("") == nil)
    #expect(ItemDetailAboutPresentation.trimmed("   \n  ") == nil)
    #expect(ItemDetailAboutPresentation.trimmed("<p></p>") == nil)
  }

  @Test("an audiobook carries duration and expected download size, not narrator")
  func audiobookRowsCarryDurationAndDownloadSize() {
    let item = Self.summary(
      author: "James S. A. Corey", series: "The Expanse", narrator: "Jefferson Mays",
      durationSeconds: 73_620, category: .audiobook,
      addedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let rows = ItemDetailAboutPresentation.rows(
      for: item, formattedDuration: "20h 27m", formattedAudioDownloadSize: "1.2 GB")

    #expect(rows.map(\.label) == ["Duration", "Download size"])
    #expect(rows.first(where: { $0.label == "Duration" })?.value == "20h 27m")
    #expect(rows.first(where: { $0.label == "Download size" })?.value == "1.2 GB")
  }

  /// An ebook has no narrator. A row per absent field would be a column of "Unknown".
  @Test("absent and blank fields produce no row at all")
  func absentFieldsProduceNoRow() {
    let item = Self.summary(
      author: nil, series: nil, narrator: "   ", durationSeconds: 0, addedAt: nil)
    #expect(ItemDetailAboutPresentation.rows(for: item, formattedDuration: "0m").isEmpty)
  }

  @Test("an ebook never gets a duration row")
  func ebookGetsNoDurationRow() {
    let item = Self.summary(
      author: nil, series: nil, narrator: nil, durationSeconds: 3600, addedAt: nil)
    #expect(ItemDetailAboutPresentation.rows(for: item, formattedDuration: "1h").isEmpty)
  }

  @Test("a mixed title labels audio and ebook downloads separately")
  func mixedTitleLabelsDownloadsSeparately() {
    let item = ItemSummary(
      serverItemId: "item-1", mediaKind: "book", title: "A Book", author: "An Author",
      durationSeconds: 3_600, category: .audiobook, hasReadableEbook: true,
      audioDownloadExpectedBytes: 1_000, ebookDownloadExpectedBytes: 200)

    let rows = ItemDetailAboutPresentation.rows(
      for: item, formattedDuration: "1h", formattedAudioDownloadSize: "1 MB",
      formattedEbookDownloadSize: "200 KB")

    #expect(rows.map(\.label) == ["Duration", "Audiobook download", "eBook download"])
  }

  @Test("an ebook-only title uses the generic download-size label")
  func ebookOnlyTitleUsesGenericDownloadSizeLabel() {
    let item = ItemSummary(
      serverItemId: "ebook-1", mediaKind: "book", title: "An eBook", author: "An Author",
      durationSeconds: nil, category: .ebook, hasReadableEbook: true,
      ebookDownloadExpectedBytes: 200)

    let rows = ItemDetailAboutPresentation.rows(
      for: item, formattedDuration: nil, formattedEbookDownloadSize: "200 KB")

    #expect(rows == [ItemDetailAboutRow(label: "Download size", value: "200 KB")])
  }

  @Test("missing expected bytes omit size rows")
  func missingExpectedBytesOmitSizeRows() {
    let item = Self.summary(
      author: "An Author", series: nil, narrator: "A Narrator", durationSeconds: 3_600,
      category: .audiobook, addedAt: nil)

    #expect(
      ItemDetailAboutPresentation.rows(for: item, formattedDuration: "1h").map(\.label)
        == ["Duration"])
  }

  @Test("rows keep a stable order so the list doesn't reshuffle between items")
  func rowsKeepAStableOrder() {
    let item = Self.summary(
      author: "An Author", series: "A Series", narrator: "A Narrator", durationSeconds: 3600,
      category: .audiobook, addedAt: Date(timeIntervalSince1970: 1_700_000_000))
    #expect(
      ItemDetailAboutPresentation.rows(for: item, formattedDuration: "1h").map(\.label)
        == ["Duration"])
  }

  private static func summary(
    author: String?, series: String?, narrator: String?, durationSeconds: Double = 0,
    category: ItemMediaCategory = .ebook, addedAt: Date?
  ) -> ItemSummary {
    ItemSummary(
      serverItemId: "item-1", mediaKind: "book", title: "A Book", author: author,
      durationSeconds: durationSeconds, category: category, addedAt: addedAt, seriesName: series,
      narratorName: narrator)
  }
}

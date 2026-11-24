import Foundation
import TestSupport
import Testing

@testable import ABSApi

/// One supplement list from `media.ebookFile` and the item-root `libraryFiles[]`, PDFs on audio
/// items only, deduplicated by `ino`.
@Suite("Item supplement files")
struct ItemSupplementFilesTests {

  private func decode(
    mediaType: String = "book",
    ebookFile: [String: Any]? = nil,
    libraryFiles: Any? = nil,
    hasAudio: Bool = true
  ) throws -> ItemDetail {
    var object = try #require(
      JSONSerialization.jsonObject(with: Fixtures.data(named: "book-item-expanded")) as? [String: Any]
    )
    object["mediaType"] = mediaType
    var media = try #require(object["media"] as? [String: Any])
    media["ebookFile"] = ebookFile ?? NSNull()
    if hasAudio == false {
      media["audioFiles"] = []
      media["tracks"] = []
    }
    object["media"] = media
    object["libraryFiles"] = libraryFiles ?? NSNull()
    let data = try JSONSerialization.data(withJSONObject: object)
    let dto = try JSONDecoder().decode(ItemDetailDTO.self, from: data)
    return ItemDetail(dto: dto, id: "item_book_fixture")
  }

  private func supplements(_ detail: ItemDetail) -> [SupplementFileInfo] {
    guard case .book(let book) = detail.media else { return [] }
    return book.supplements
  }

  private func file(_ ino: Any, _ filename: String, ext: String?, size: Any? = 4096) -> [String: Any] {
    var metadata: [String: Any] = ["filename": filename, "path": "<redacted>"]
    if let ext { metadata["ext"] = ext }
    if let size { metadata["size"] = size }
    return ["ino": ino, "metadata": metadata]
  }

  @Test("a primary PDF ebook on an audio item is a supplement")
  func primaryPDFIsSupplement() throws {
    let detail = try decode(ebookFile: file("900", "Maps.pdf", ext: "pdf"))
    #expect(supplements(detail) == [SupplementFileInfo(ino: "900", filename: "Maps.pdf", size: 4096)])
  }

  @Test("library-file PDFs follow the primary one and dedupe by ino")
  func libraryFilesAppendAndDedupe() throws {
    let detail = try decode(
      ebookFile: file("900", "Maps.pdf", ext: ".pdf"),
      libraryFiles: [
        file("1", "book.m4b", ext: "m4b"),
        file("900", "Maps.pdf", ext: ".pdf"),
        file(901, "Tables.pdf", ext: "pdf"),
        file("902", "cover.jpg", ext: "jpg"),
      ])
    #expect(supplements(detail).map(\.ino) == ["900", "901"])
  }

  @Test("both leading-dot and bare extensions match, case-insensitively")
  func extensionNormalisation() throws {
    let detail = try decode(libraryFiles: [
      file("1", "a.pdf", ext: ".pdf"), file("2", "b.PDF", ext: "PDF"), file("3", "c.pdf", ext: " ..pdf "),
    ])
    #expect(supplements(detail).map(\.ino) == ["1", "2", "3"])
  }

  @Test("an integer ino of zero decodes as the string \"0\"")
  func integerIno() throws {
    let detail = try decode(libraryFiles: [file(0, "a.pdf", ext: "pdf")])
    #expect(supplements(detail).map(\.ino) == ["0"])
  }

  @Test("entries without an ino or a positive size are skipped")
  func incompleteEntriesSkipped() throws {
    let detail = try decode(libraryFiles: [
      ["metadata": ["filename": "a.pdf", "ext": "pdf", "size": 10]],
      file("2", "b.pdf", ext: "pdf", size: nil),
      file("3", "c.pdf", ext: "pdf", size: 0),
      file("4", "d.pdf", ext: "pdf"),
    ])
    #expect(supplements(detail).map(\.ino) == ["4"])
  }

  @Test("an EPUB primary is not a supplement")
  func epubPrimaryIgnored() throws {
    let detail = try decode(ebookFile: file("900", "Book.epub", ext: "epub"))
    #expect(supplements(detail).isEmpty)
    guard case .book(let book) = detail.media else {
      Issue.record("expected book")
      return
    }
    #expect(book.ebookFile?.ext == "epub")
  }

  @Test("a standalone PDF book without audio has no supplements")
  func noAudioNoSupplements() throws {
    let detail = try decode(
      ebookFile: file("900", "Book.pdf", ext: "pdf"),
      libraryFiles: [file("901", "Extra.pdf", ext: "pdf")], hasAudio: false)
    #expect(supplements(detail).isEmpty)
  }

  @Test("a malformed libraryFiles value never fails the item")
  func malformedLibraryFilesTolerated() throws {
    let detail = try decode(libraryFiles: "not an array")
    #expect(supplements(detail).isEmpty)
    #expect(detail.media != nil)
  }

  @Test("a podcast's root libraryFiles never yield supplements")
  func podcastIgnored() throws {
    let data = try Fixtures.data(named: "podcast-item-expanded-live")
    let dto = try JSONDecoder().decode(ItemDetailDTO.self, from: data)
    #expect(dto.libraryFiles.isEmpty)
  }

  @Test("the captured book fixture decodes with no supplements")
  func capturedFixtureHasNone() throws {
    let dto = try JSONDecoder().decode(ItemDetailDTO.self, from: try Fixtures.data(named: "book-item-expanded"))
    #expect(dto.libraryFiles.count == 1)
    #expect(supplements(ItemDetail(dto: dto, id: "x")).isEmpty)
  }
}

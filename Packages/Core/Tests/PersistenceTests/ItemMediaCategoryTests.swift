import Foundation
import Testing

@testable import Persistence

/// T4B.2: `ItemMediaCategory.derive` is the one place audiobook-vs-podcast-vs-ebook logic may
/// live (phase-4b-home-screen.md). ABS calls an EPUB-only item `mediaType: "book"` like an
/// audiobook, so the category comes from the minified media signals, not `mediaKind` alone
/// (podcasts excepted, which `mediaKind` identifies correctly).
@Suite struct ItemMediaCategoryTests {

  @Test func podcastMediaKindWinsRegardlessOfOtherSignals() {
    #expect(
      ItemMediaCategory.derive(mediaKind: "podcast", numAudioFiles: nil, ebookFormat: nil)
        == .podcast)
    #expect(
      ItemMediaCategory.derive(mediaKind: "podcast", numAudioFiles: 12, ebookFormat: "epub")
        == .podcast)
    #expect(
      ItemMediaCategory.derive(mediaKind: "podcast", numAudioFiles: 0, ebookFormat: "epub")
        == .podcast)
  }

  @Test func zeroOrNilAudioFilesWithAnEbookFormatIsAnEbook() {
    #expect(
      ItemMediaCategory.derive(mediaKind: "book", numAudioFiles: 0, ebookFormat: "epub")
        == .ebook)
    #expect(
      ItemMediaCategory.derive(mediaKind: "book", numAudioFiles: nil, ebookFormat: "pdf")
        == .ebook)
  }

  @Test func anyAudioFilesMakeItAnAudiobookEvenWithAnEbookFormatPresent() {
    #expect(
      ItemMediaCategory.derive(mediaKind: "book", numAudioFiles: 1, ebookFormat: "epub")
        == .audiobook)
    #expect(ItemMediaCategory.hasReadableEbook(ebookFormat: "epub"))
    #expect(
      ItemMediaCategory.derive(mediaKind: "book", numAudioFiles: 42, ebookFormat: nil)
        == .audiobook)
  }

  @Test func documentPresenceAndReadableEbookAreSeparateFacts() {
    #expect(ItemMediaCategory.hasDocument(ebookFormat: nil) == false)
    #expect(ItemMediaCategory.hasDocument(ebookFormat: "") == false)
    #expect(ItemMediaCategory.hasDocument(ebookFormat: "  ") == false)
    #expect(ItemMediaCategory.hasDocument(ebookFormat: "pdf"))
    #expect(ItemMediaCategory.hasDocument(ebookFormat: " .EPUB "))

    #expect(ItemMediaCategory.hasReadableEbook(ebookFormat: nil) == false)
    #expect(ItemMediaCategory.hasReadableEbook(ebookFormat: "") == false)
    #expect(ItemMediaCategory.hasReadableEbook(ebookFormat: "pdf") == false)
    #expect(ItemMediaCategory.hasReadableEbook(ebookFormat: "epub"))
    #expect(ItemMediaCategory.hasReadableEbook(ebookFormat: " .EPUB "))

    #expect(
      ItemMediaCategory.derive(mediaKind: "book", numAudioFiles: 2, ebookFormat: "epub")
        == .audiobook)
    #expect(ItemMediaCategory.hasReadableEbook(ebookFormat: "epub"))
  }

  @Test func allSignalsNilFallsBackToAudiobook() {
    #expect(
      ItemMediaCategory.derive(mediaKind: "book", numAudioFiles: nil, ebookFormat: nil)
        == .audiobook)
  }

  @Test func emptyStringEbookFileFormatIsTreatedAsAbsent() {
    #expect(
      ItemMediaCategory.derive(mediaKind: "book", numAudioFiles: 0, ebookFormat: "")
        == .audiobook)
    #expect(
      ItemMediaCategory.derive(mediaKind: "book", numAudioFiles: nil, ebookFormat: "")
        == .audiobook)
    #expect(
      ItemMediaCategory.derive(mediaKind: "book", numAudioFiles: nil, ebookFormat: "  ")
        == .audiobook)
  }
}

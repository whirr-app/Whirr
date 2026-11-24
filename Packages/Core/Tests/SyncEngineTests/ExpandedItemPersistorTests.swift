import Foundation
import Testing

@testable import ABSApi
@testable import SyncEngine

@Suite struct ExpandedItemPersistorTests {
  @Test func completeAudioCatalogAndEbookExposeExpectedTransferBytes() {
    let extras = ExpandedItemPersistor.persistable(
      from: detail(
        audioFiles: AudioFileCatalog(
          files: [
            audioFile(index: 0, size: 1_000),
            audioFile(index: 1, size: 2_500),
          ],
          invalidEntryCount: 0),
        ebookSize: 4_000))

    #expect(extras.audioDownloadExpectedBytes == 3_500)
    #expect(extras.ebookDownloadExpectedBytes == 4_000)
  }

  @Test func incompleteOrEmptyAudioCatalogDoesNotClaimACompleteDownloadSize() {
    let incomplete = ExpandedItemPersistor.persistable(
      from: detail(
        audioFiles: AudioFileCatalog(
          files: [audioFile(index: 0, size: 1_000)],
          invalidEntryCount: 1),
        ebookSize: nil))
    let empty = ExpandedItemPersistor.persistable(
      from: detail(
        audioFiles: AudioFileCatalog(files: [], invalidEntryCount: 0),
        ebookSize: nil))

    #expect(incomplete.audioDownloadExpectedBytes == nil)
    #expect(empty.audioDownloadExpectedBytes == nil)
  }

  @Test func overflowingAudioCatalogAndNonPositiveEbookSizeAreOmitted() {
    let extras = ExpandedItemPersistor.persistable(
      from: detail(
        audioFiles: AudioFileCatalog(
          files: [
            audioFile(index: 0, size: Int.max),
            audioFile(index: 1, size: 1),
          ],
          invalidEntryCount: 0),
        ebookSize: 0))

    #expect(extras.audioDownloadExpectedBytes == nil)
    #expect(extras.ebookDownloadExpectedBytes == nil)
  }

  private func detail(audioFiles: AudioFileCatalog, ebookSize: Int?) -> ItemDetail {
    ItemDetail(
      id: "item",
      libraryID: "library",
      mediaType: "book",
      media: .book(
        BookMedia(
          title: "Book",
          subtitle: nil,
          authorName: "Author",
          narratorName: "Narrator",
          seriesName: "Series",
          description: nil,
          duration: 60,
          audioFiles: audioFiles,
          tracks: [],
          chapters: [],
          ebookFile: ebookSize.map {
            EbookFileInfo(ino: "ebook", ext: "epub", filename: nil, size: $0)
          })))
  }

  private func audioFile(index: Int, size: Int) -> AudioFileInfo {
    AudioFileInfo(
      index: index,
      ino: "audio-\(index)",
      expectedSize: size,
      mimeType: "audio/mpeg",
      duration: 60)
  }
}

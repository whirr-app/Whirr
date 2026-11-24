import Foundation
import Persistence
import ReaderCore
import TestSupport
import Testing

@testable import AppModel

/// The ebook detail screen's Contents tab. ABS chapters are audio-track markers, so an ebook-only
/// item shows the EPUB's own table of contents, read from the downloaded file rather than the
/// server.
@Suite(.timeLimit(.minutes(1))) struct ItemContentsModelTests {

  @MainActor
  @Test("a downloaded ebook loads its table of contents from the local file")
  func downloadedEbookLoadsItsTableOfContents() async {
    let reader = FakeReaderStateReadingForContents()
    let toc = FakeEPUBTableOfContentsReading()
    let fileURL = URL(fileURLWithPath: "/tmp/book.epub")
    toc.result = .success([
      TOCEntry(title: "Part One", href: "part1.xhtml", depth: 0),
      TOCEntry(title: "Chapter One", href: "ch1.xhtml", depth: 1),
    ])

    let model = ItemContentsModel(itemId: "item-1", readerReading: reader, tableOfContents: toc)
    reader.emit(.downloadedReady(fileURL: fileURL))

    await waitUntil {
      if case .loaded = model.state { return true }
      return false
    }

    guard case .loaded(let entries) = model.state else {
      Issue.record("expected loaded, got \(model.state)")
      return
    }
    #expect(entries.map(\.title) == ["Part One", "Chapter One"])
    #expect(entries.map(\.depth) == [0, 1])
    #expect(toc.requestedURLs == [fileURL])
  }

  /// The ToC lives inside the EPUB, so there is nothing to read until the file is on the device.
  /// This is a "download it" state, not a blank "No Chapters".
  @MainActor
  @Test("an ebook that isn't downloaded asks for the download rather than reporting emptiness")
  func notDownloadedEbookAsksForTheDownload() async {
    let reader = FakeReaderStateReadingForContents()
    let toc = FakeEPUBTableOfContentsReading()

    let model = ItemContentsModel(itemId: "item-1", readerReading: reader, tableOfContents: toc)
    reader.emit(.availableNotDownloaded)

    await waitUntil { model.state == .needsDownload }
    #expect(toc.requestedURLs.isEmpty, "nothing to open, so nothing should be opened")
  }

  @MainActor
  @Test("a download in progress reports progress rather than an empty contents list")
  func downloadInProgressReportsProgress() async {
    let reader = FakeReaderStateReadingForContents()
    let toc = FakeEPUBTableOfContentsReading()

    let model = ItemContentsModel(itemId: "item-1", readerReading: reader, tableOfContents: toc)
    reader.emit(.downloading(progress: 0.4))

    await waitUntil { model.state == .downloading(progress: 0.4) }
    #expect(toc.requestedURLs.isEmpty)
  }

  @MainActor
  @Test("an unopenable or protected file reports unavailable, never a false empty list")
  func unopenableFileReportsUnavailable() async {
    let reader = FakeReaderStateReadingForContents()
    let toc = FakeEPUBTableOfContentsReading()
    toc.result = .failure(.drmProtected)

    let model = ItemContentsModel(itemId: "item-1", readerReading: reader, tableOfContents: toc)
    reader.emit(.downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/drm.epub")))

    await waitUntil { model.state == .unavailable }
  }

  /// A publication can legitimately ship no navigation document. That is a real empty table of
  /// contents, and it must stay distinguishable from "we couldn't open the file".
  @MainActor
  @Test("an EPUB with no navigation document reports an empty contents list, not unavailable")
  func epubWithNoNavigationDocumentReportsEmpty() async {
    let reader = FakeReaderStateReadingForContents()
    let toc = FakeEPUBTableOfContentsReading()
    toc.result = .success([])

    let model = ItemContentsModel(itemId: "item-1", readerReading: reader, tableOfContents: toc)
    reader.emit(.downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/plain.epub")))

    await waitUntil { model.state == .loaded([]) }
  }

  // MARK: - Durable contents

  /// Stored so that deleting the download does not delete the contents list with it.
  @MainActor
  @Test("a stored table of contents shows even though the file is no longer downloaded")
  func storedContentsSurviveTheDownloadBeingRemoved() async {
    let reader = FakeReaderStateReadingForContents()
    let toc = FakeEPUBTableOfContentsReading()
    let access = FakeEbookTableOfContentsAccess()
    access.stored["item-1"] = [
      StoredEbookTOCEntry(
        position: 0, title: "Chapter One", href: "ch1.xhtml", depth: 0, startProgression: 0.1)
    ]

    let model = ItemContentsModel(
      itemId: "item-1", readerReading: reader, tableOfContents: toc, contentsAccess: access)
    reader.emit(.availableNotDownloaded)

    await waitUntil {
      if case .loaded = model.state { return true }
      return false
    }
    guard case .loaded(let entries) = model.state else {
      Issue.record("expected loaded, got \(model.state)")
      return
    }
    #expect(entries.map(\.title) == ["Chapter One"])
    #expect(entries.first?.startProgression == 0.1)
    #expect(toc.requestedURLs.isEmpty, "the stored snapshot answers without opening a file")
  }

  @MainActor
  @Test("parsing a downloaded ebook stores its contents for later")
  func parsingADownloadedEbookStoresItsContents() async {
    let reader = FakeReaderStateReadingForContents()
    let toc = FakeEPUBTableOfContentsReading()
    let access = FakeEbookTableOfContentsAccess()
    toc.result = .success([
      TOCEntry(title: "Part One", href: "part1.xhtml", depth: 0, startProgression: 0),
      TOCEntry(title: "Chapter One", href: "ch1.xhtml", depth: 1, startProgression: 0.25),
    ])

    let model = ItemContentsModel(
      itemId: "item-1", readerReading: reader, tableOfContents: toc, contentsAccess: access)
    reader.emit(.downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")))

    await waitUntil {
      if case .loaded = model.state { return true }
      return false
    }
    #expect(
      access.stored["item-1"] == [
        StoredEbookTOCEntry(
          position: 0, title: "Part One", href: "part1.xhtml", depth: 0, startProgression: 0),
        StoredEbookTOCEntry(
          position: 1, title: "Chapter One", href: "ch1.xhtml", depth: 1, startProgression: 0.25),
      ])
    #expect(model.state == .loaded(toc.result.value ?? []))
  }

  @MainActor
  @Test("a stored snapshot spares the downloaded file a second parse")
  func aStoredSnapshotSparesTheFileASecondParse() async {
    let reader = FakeReaderStateReadingForContents()
    let toc = FakeEPUBTableOfContentsReading()
    let access = FakeEbookTableOfContentsAccess()
    access.stored["item-1"] = [
      StoredEbookTOCEntry(
        position: 0, title: "Chapter One", href: "ch1.xhtml", depth: 0, startProgression: 0)
    ]

    let model = ItemContentsModel(
      itemId: "item-1", readerReading: reader, tableOfContents: toc, contentsAccess: access)
    reader.emit(.downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")))

    await waitUntil {
      if case .loaded = model.state { return true }
      return false
    }
    #expect(toc.requestedURLs.isEmpty)
  }

  /// A publication that genuinely ships no navigation document stores nothing, so it is re-parsed
  /// next time rather than being remembered as permanently contents-less.
  @MainActor
  @Test("an empty parse is not stored as a snapshot")
  func anEmptyParseIsNotStored() async {
    let reader = FakeReaderStateReadingForContents()
    let toc = FakeEPUBTableOfContentsReading()
    let access = FakeEbookTableOfContentsAccess()
    toc.result = .success([])

    let model = ItemContentsModel(
      itemId: "item-1", readerReading: reader, tableOfContents: toc, contentsAccess: access)
    reader.emit(.downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/plain.epub")))

    await waitUntil { model.state == .loaded([]) }
    #expect(access.stored["item-1"] == nil)
  }

  @MainActor
  @Test("the model carries the reading position that marks entries read")
  func theModelCarriesTheReadingPosition() async {
    let reader = FakeReaderStateReadingForContents()
    let toc = FakeEPUBTableOfContentsReading()

    let model = ItemContentsModel(itemId: "item-1", readerReading: reader, tableOfContents: toc)
    #expect(model.ebookProgress == nil)

    reader.emitProgress(0.42)
    await waitUntil { model.ebookProgress == 0.42 }
  }
}

// MARK: - Fakes

final class FakeEPUBTableOfContentsReading: EPUBTableOfContentsReading, @unchecked Sendable {
  private let lock = NSLock()
  private var storedResult: Result<[TOCEntry], EPUBRenderingOpenFailure> = .success([])
  private var storedRequests: [URL] = []

  var result: Result<[TOCEntry], EPUBRenderingOpenFailure> {
    get { lock.withLock { storedResult } }
    set { lock.withLock { storedResult = newValue } }
  }

  var requestedURLs: [URL] { lock.withLock { storedRequests } }

  func tableOfContents(localFileURL: URL) async throws -> [TOCEntry] {
    lock.withLock { storedRequests.append(localFileURL) }
    return try result.get()
  }
}

final class FakeReaderStateReadingForContents: ReaderStateReading, @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: AsyncStream<ReaderState>.Continuation?
  private var progressContinuation: AsyncStream<Double?>.Continuation?

  func observeReaderState(itemId: String) -> AsyncStream<ReaderState> {
    AsyncStream { continuation in
      lock.withLock { self.continuation = continuation }
    }
  }

  func observeEbookProgress(itemId: String) -> AsyncStream<Double?> {
    AsyncStream { continuation in
      lock.withLock { self.progressContinuation = continuation }
    }
  }

  func emit(_ state: ReaderState) {
    lock.withLock { continuation }?.yield(state)
  }

  func emitProgress(_ progress: Double?) {
    lock.withLock { progressContinuation }?.yield(progress)
  }
}

final class FakeEbookTableOfContentsAccess: EbookTableOfContentsAccess, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String: [StoredEbookTOCEntry]] = [:]

  var stored: [String: [StoredEbookTOCEntry]] {
    get { lock.withLock { storage } }
    set { lock.withLock { storage = newValue } }
  }

  func fetchTableOfContents(itemId: String) async throws -> [StoredEbookTOCEntry] {
    lock.withLock { storage[itemId] ?? [] }
  }

  func storeTableOfContents(_ entries: [StoredEbookTOCEntry], itemId: String) async throws {
    lock.withLock { storage[itemId] = entries }
  }
}

extension Result where Success == [TOCEntry] {
  var value: [TOCEntry]? { try? get() }
}

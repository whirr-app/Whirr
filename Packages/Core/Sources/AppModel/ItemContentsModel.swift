import Foundation
import Observation
import Persistence
import ReaderCore

/// The ebook detail screen's Contents tab.
///
/// ABS chapters are audio-track markers, so an ebook-only item's `media.chapters` is empty. The
/// EPUB's own table of contents lives in the file, so this model is driven by `ReaderState`, not a
/// server fetch.
///
/// Once parsed, the flattened list is stored beside the item, outliving the download, with each
/// entry's `startProgression` so the tab can mark entries read against `observeEbookProgress`.
@MainActor
@Observable
public final class ItemContentsModel {
  public enum State: Equatable, Sendable {
    /// No local file yet and nothing stored, so there is nothing to read a contents list out of.
    case needsDownload
    case downloading(progress: Double)
    case loading
    case loaded([TOCEntry])
    /// The file is present but could not be opened (protected, corrupt, or missing on disk).
    case unavailable
  }

  public private(set) var state: State = .loading

  /// The whole-book reading position, on `ReadingPosition.totalProgression`'s scale.
  /// `ItemContentsPresentation` turns it into per-entry read state.
  public private(set) var ebookProgress: Double?

  @ObservationIgnored private var readerStateTask: Task<Void, Never>?
  @ObservationIgnored private var progressTask: Task<Void, Never>?
  @ObservationIgnored private var loadTask: Task<Void, Never>?

  /// The file the current `loaded`/`loading` state came from, so a repeated `downloadedReady` for
  /// the same URL doesn't reopen the publication on every reader-state emission.
  private var loadedFileURL: URL?

  /// Set once a stored snapshot has been adopted. It outranks every download state: a contents
  /// list that survived the file being deleted must not be replaced by "Not Downloaded".
  private var hasStoredContents = false

  public init(
    itemId: String,
    readerReading: any ReaderStateReading,
    tableOfContents: any EPUBTableOfContentsReading,
    contentsAccess: any EbookTableOfContentsAccess = NoOpEbookTableOfContentsAccess()
  ) {
    // Subscribed synchronously in `init`, as `ItemDetailModel` does: construction never awaits I/O.
    let readerStateStream = readerReading.observeReaderState(itemId: itemId)
    let progressStream = readerReading.observeEbookProgress(itemId: itemId)

    readerStateTask = Task { [weak self] in
      // Read the stored snapshot before applying the first reader state, so a cached item does
      // not flash "Not Downloaded" while the read is in flight.
      let stored = (try? await contentsAccess.fetchTableOfContents(itemId: itemId)) ?? []
      // Scoped so the strong binding ends here: holding `self` across the loop below would keep
      // the model alive for as long as the stream runs.
      if let self { self.adopt(stored) } else { return }

      for await readerState in readerStateStream {
        guard let self else { return }
        self.apply(
          readerState,
          tableOfContents: tableOfContents,
          contentsAccess: contentsAccess,
          itemId: itemId)
      }
    }

    progressTask = Task { [weak self] in
      for await progress in progressStream {
        guard let self else { return }
        self.ebookProgress = progress
      }
    }
  }

  deinit {
    readerStateTask?.cancel()
    progressTask?.cancel()
    loadTask?.cancel()
  }

  private func adopt(_ stored: [StoredEbookTOCEntry]) {
    guard stored.isEmpty == false else { return }
    hasStoredContents = true
    state = .loaded(stored.map(Self.entry(from:)))
  }

  private func apply(
    _ readerState: ReaderState,
    tableOfContents: any EPUBTableOfContentsReading,
    contentsAccess: any EbookTableOfContentsAccess,
    itemId: String
  ) {
    // A stored snapshot already answers the tab's question, whatever the file is currently doing.
    guard hasStoredContents == false else { return }

    switch readerState {
    case .downloadedReady(let fileURL):
      load(
        fileURL: fileURL,
        tableOfContents: tableOfContents,
        contentsAccess: contentsAccess,
        itemId: itemId)
    case .downloading(let progress), .downloadHeld(_, let progress):
      reset(to: .downloading(progress: progress))
    case .availableNotDownloaded, .downloadedButFileMissing, .downloadFailed, .downloadRejected:
      reset(to: .needsDownload)
    case .noEpubAdvertised, .ebookIdentityNotFetched, .advertisedButUnavailable:
      reset(to: .unavailable)
    }
  }

  private func reset(to newState: State) {
    guard state != newState else { return }
    loadTask?.cancel()
    loadTask = nil
    loadedFileURL = nil
    state = newState
  }

  private func load(
    fileURL: URL,
    tableOfContents: any EPUBTableOfContentsReading,
    contentsAccess: any EbookTableOfContentsAccess,
    itemId: String
  ) {
    guard loadedFileURL != fileURL else { return }
    loadedFileURL = fileURL
    loadTask?.cancel()
    state = .loading
    loadTask = Task { [weak self] in
      let entries = try? await tableOfContents.tableOfContents(localFileURL: fileURL)

      // An empty parse ("no navigation document") is not stored: it would be indistinguishable
      // from having nothing stored, and the item would never be re-parsed.
      if let entries, entries.isEmpty == false {
        try? await contentsAccess.storeTableOfContents(
          entries.enumerated().map(Self.storedEntry(position:entry:)), itemId: itemId)
      }

      guard let self, Task.isCancelled == false else { return }
      if entries?.isEmpty == false { self.hasStoredContents = true }
      self.state = entries.map(State.loaded) ?? .unavailable
    }
  }

  private static func entry(from stored: StoredEbookTOCEntry) -> TOCEntry {
    TOCEntry(
      title: stored.title,
      href: stored.href,
      depth: stored.depth,
      startProgression: stored.startProgression)
  }

  private static func storedEntry(position: Int, entry: TOCEntry) -> StoredEbookTOCEntry {
    StoredEbookTOCEntry(
      position: position,
      title: entry.title,
      href: entry.href,
      depth: entry.depth,
      startProgression: entry.startProgression)
  }
}

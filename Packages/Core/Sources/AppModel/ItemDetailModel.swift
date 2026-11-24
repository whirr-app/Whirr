import Observation
import Persistence

/// The detail-screen state for the EPUB reader. `advertisedButUnavailable` is a visible
/// explanation without a Read action. `protected` reserves the renderer outcome for when
/// protected-content detection reaches AppModel.
///
/// A finished book has no state of its own: it is `read`/`continueReading` like any other, since
/// finished says nothing about openability. The finished projection only renames the action
/// (`ReaderDetailCopy`).
public enum ReadAffordanceState: Sendable, Equatable {
  case none
  case read
  case continueReading(percent: Int)
  case downloading(progress: Double)
  case advertisedButUnavailable
  case protected
}

/// Read-only item detail. ABS items start from `LibraryReading`'s persisted current projection
/// and stay live through `observeItemDetail`; RSS items start from the device-owned native-show
/// projection and stay live through its single-show observation. A route seed is the synchronous
/// first paint for either source.
@MainActor
@Observable
public final class ItemDetailModel {
  public enum State: Sendable, Equatable {
    case loading
    case loaded(ItemSummary)
    /// The item is absent or soft-deleted (a stale deep link or a removed item).
    case notFound
  }

  public private(set) var state: State
  public private(set) var readAffordance: ReadAffordanceState = .none

  /// The detail row's controls in reading order. A parsed EPUB keeps its Chapters control while
  /// the reader state is still unresolved, because contents availability does not depend on the
  /// reader action's title.
  public func actionLayout(isAccessibilitySize: Bool) -> ItemDetailActionLayout {
    guard case .loaded(let summary) = state else { return .horizontal([]) }
    let capability = ItemMediaCapability.derive(
      category: summary.category, hasReadableEbook: summary.hasReadableEbook)
    // `detailActionTitle` is nil purely by affordance state; the finished flag swaps which title,
    // never whether there is one, so `false` resolves visibility for finished items too.
    let hasVisibleReadAction =
      ReaderDetailCopy.detailActionTitle(for: readAffordance, isFinished: false) != nil
    return ItemDetailActionLayout.resolve(
      capability: capability,
      hasVisibleReadAction: hasVisibleReadAction,
      isAccessibilitySize: isAccessibilitySize)
  }

  /// Reader-side finish is a capability of ebook-category items only. The shared progress flag
  /// is item-wide, so a bundled-EPUB audiobook must never expose this reader finish affordance.
  public var offersReaderFinish: Bool {
    guard itemCategory == .ebook else { return false }
    return readAffordance == .read || isContinueReading
  }

  public var readAffordanceCopy: String? {
    ReaderDetailCopy.text(for: readAffordance)
  }

  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var readerStateTask: Task<Void, Never>?
  @ObservationIgnored private var ebookProgressTask: Task<Void, Never>?

  private var readerState: ReaderState = .noEpubAdvertised
  private var ebookProgress: Double?

  public init(
    itemId: String,
    seed: ItemSummary? = nil,
    library: any LibraryReading,
    nativePodcastShowsReading: any NativePodcastShowsReading,
    readerReading: any ReaderStateReading = NoOpReaderStateReading()
  ) {
    state = seed.map(State.loaded) ?? .loading
    switch PodcastSourceIdentity(itemId: itemId)?.source {
    case .abs:
      // The observation is the sole loader for an unseeded ABS route. Its baseline arrives
      // off-main, so the initializer remains synchronous and never performs a database read.
      let stream = library.observeItemDetail(itemId: itemId)
      task = Task { [weak self] in
        for await summary in stream {
          guard let self else { return }
          self.state = summary.map(State.loaded) ?? .notFound
          self.updateReadAffordance()
        }
      }
    case .rss:
      // RSS is device-owned. Its baseline arrives off-main from the native reading dependency, so
      // the initializer remains synchronous and never performs a database read.
      let stream = nativePodcastShowsReading.observeShow(itemId: itemId)
      task = Task { [weak self] in
        for await summary in stream {
          guard let self else { return }
          self.state = summary.map(State.loaded) ?? .notFound
          self.updateReadAffordance()
        }
      }
    case nil:
      if seed == nil { state = .notFound }
    }

    let readerStateStream = readerReading.observeReaderState(itemId: itemId)
    readerStateTask = Task { [weak self] in
      for await readerState in readerStateStream {
        guard let self else { return }
        self.readerState = readerState
        self.updateReadAffordance()
      }
    }

    let ebookProgressStream = readerReading.observeEbookProgress(itemId: itemId)
    ebookProgressTask = Task { [weak self] in
      for await ebookProgress in ebookProgressStream {
        guard let self else { return }
        self.ebookProgress = ebookProgress
        self.updateReadAffordance()
      }
    }

    updateReadAffordance()
  }

  deinit {
    task?.cancel()
    readerStateTask?.cancel()
    ebookProgressTask?.cancel()
  }

  private var itemCategory: ItemMediaCategory? {
    guard case .loaded(let summary) = state else { return nil }
    return summary.category
  }

  private var isContinueReading: Bool {
    if case .continueReading = readAffordance { return true }
    return false
  }

  private func updateReadAffordance() {
    guard case .loaded(let summary) = state else {
      readAffordance = .none
      return
    }
    let capability = ItemMediaCapability.derive(
      category: summary.category, hasReadableEbook: summary.hasReadableEbook)
    guard capability.supportsReading else {
      readAffordance = .none
      return
    }

    switch readerState {
    case .noEpubAdvertised, .ebookIdentityNotFetched:
      readAffordance = .none
    case .advertisedButUnavailable:
      readAffordance = .advertisedButUnavailable
    case .availableNotDownloaded, .downloadedButFileMissing, .downloadFailed, .downloadRejected:
      readAffordance = .read
    case .downloading(let progress), .downloadHeld(_, let progress):
      // Detail's own download cluster names the hold reason; the Read affordance only needs to know
      // a transfer is outstanding.
      readAffordance = .downloading(progress: progress)
    case .downloadedReady:
      if let ebookProgress, ebookProgress > 0 {
        readAffordance = .continueReading(percent: Self.percent(ebookProgress))
      } else {
        readAffordance = .read
      }
    }
  }

  private static func percent(_ fraction: Double) -> Int {
    Int((min(max(fraction, 0), 1) * 100).rounded())
  }
}

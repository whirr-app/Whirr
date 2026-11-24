import Foundation
import Persistence
import TestSupport
import Testing

@testable import AppModel

/// `ItemDetailModel` is read-only, seeded from and kept live by its source-owned reading.
@Suite(.timeLimit(.minutes(1))) struct ItemDetailModelTests {
  @MainActor
  @Test("an unseeded model does not perform a synchronous current-item read")
  func unseededModelDoesNotPerformSynchronousCurrentRead() async {
    let library = FakeLibraryReading()
    let model = ItemDetailModel(
      itemId: "item1", library: library,
      nativePodcastShowsReading: NoOpNativePodcastShowsReading())

    #expect(model.state == .loading)
    #expect(library.currentItemDetailReadCount == 0)

    let summary = ItemSummary(
      serverItemId: "item1", mediaKind: "podcast", title: "Observed Show", author: "Publisher",
      durationSeconds: nil, category: .podcast, itemDescription: "Observed description")
    library.pushItemDetail(summary)
    await waitUntil { model.state == .loaded(summary) }
  }

  @MainActor
  @Test("a seeded model does not perform a synchronous current-item read")
  func seededModelDoesNotPerformSynchronousCurrentRead() {
    let library = FakeLibraryReading()
    let seed = ItemSummary(
      serverItemId: "item1", mediaKind: "book", title: "Seed", author: "Author",
      durationSeconds: 42)

    let model = ItemDetailModel(
      itemId: "item1", seed: seed, library: library,
      nativePodcastShowsReading: NoOpNativePodcastShowsReading())

    #expect(model.state == .loaded(seed))
    #expect(library.currentItemDetailReadCount == 0)
  }

  @MainActor
  @Test("an unseeded RSS show resolves through the device-owned reading")
  func unseededRSSShowResolvesThroughDeviceOwnedReading() async {
    let library = FakeLibraryReading()
    let native = FakeNativePodcastShowsReading()
    let model = ItemDetailModel(
      itemId: "rss:7", library: library, nativePodcastShowsReading: native)

    #expect(model.state == .loading)
    #expect(library.itemDetailSubscriberCount == 0)
    #expect(native.observedItemIDs.count == 1)

    let summary = ItemSummary(
      serverItemId: "rss:7", mediaKind: "podcast", title: "Device Show", author: "Publisher",
      durationSeconds: nil, category: .podcast,
      artworkURL: URL(string: "https://images.example.com/show.jpg"),
      artworkFeedURL: URL(string: "https://example.com/feed.xml"))
    native.pushShow(summary)
    await waitUntil { model.state == .loaded(summary) }

    #expect(model.state == .loaded(summary))
  }

  @MainActor
  @Test("a subscribed RSS feed loads its device projection without an ABS observation")
  func subscribedRSSFeedLoadsDeviceProjectionWithoutABSObservation() async throws {
    let database = try AppDatabase.inMemory()
    let feedID = try await RSSFeedStore(database: database).subscribe(
      feedURL: URL(string: "https://example.com/device.xml")!, title: "Subscribed Show",
      author: "Device Publisher", synopsis: "Device synopsis",
      artworkURL: URL(string: "https://images.example.com/device.jpg"), subscribedAt: Date())
    let library = FakeLibraryReading()
    let model = ItemDetailModel(
      itemId: try #require(PodcastSourceIdentity.rss(feedId: feedID)).itemId,
      library: library,
      nativePodcastShowsReading: RSSPodcastReading(database: database))

    await waitUntil {
      if case .loaded(let summary) = model.state {
        return summary.title == "Subscribed Show"
      }
      return false
    }

    guard case .loaded(let summary) = model.state else {
      Issue.record("the subscribed RSS feed did not resolve")
      return
    }
    #expect(summary.author == "Device Publisher")
    #expect(summary.artworkURL == URL(string: "https://images.example.com/device.jpg"))
    #expect(summary.artworkFeedURL == URL(string: "https://example.com/device.xml"))
    #expect(library.itemDetailSubscriberCount == 0)
  }

  @MainActor
  @Test("a seeded RSS show is superseded by the live device projection")
  func seededRSSShowIsSupersededByLiveDeviceProjection() async {
    let library = FakeLibraryReading()
    let native = FakeNativePodcastShowsReading()
    let seed = ItemSummary(
      serverItemId: "rss:7", mediaKind: "podcast", title: "Device Show", author: "Publisher",
      durationSeconds: nil, category: .podcast,
      artworkURL: URL(string: "https://images.example.com/old.jpg"))
    let observed = ItemSummary(
      serverItemId: "rss:7", mediaKind: "podcast", title: "Renamed Show", author: "New Publisher",
      durationSeconds: nil, category: .podcast,
      artworkURL: URL(string: "https://images.example.com/new.jpg"))
    let model = ItemDetailModel(
      itemId: "rss:7", seed: seed, library: library, nativePodcastShowsReading: native)

    #expect(model.state == .loaded(seed))
    #expect(library.itemDetailSubscriberCount == 0)
    native.pushShow(observed)
    await waitUntil { model.state == .loaded(observed) }

    #expect(model.state == .loaded(observed))
  }

  @MainActor
  @Test("an unsubscribed RSS show resolves to not found")
  func unsubscribedRSSShowResolvesToNotFound() async {
    let library = FakeLibraryReading()
    let native = FakeNativePodcastShowsReading()
    let model = ItemDetailModel(
      itemId: "rss:999", library: library, nativePodcastShowsReading: native)

    native.pushShow(nil)
    await waitUntil { model.state == .notFound }

    #expect(model.state == .notFound)
    #expect(library.itemDetailSubscriberCount == 0)
  }

  @MainActor
  @Test("an RSS reader that emits nil reaches not found")
  func rssReaderEmittingNilReachesNotFound() async {
    let model = ItemDetailModel(
      itemId: "rss:missing", library: FakeLibraryReading(),
      nativePodcastShowsReading: NoOpNativePodcastShowsReading())

    await waitUntil { model.state != .loading }

    #expect(model.state == .notFound)
  }

  @MainActor
  @Test("an unseeded ABS show still observes the library projection")
  func unseededABSShowStillObservesLibraryProjection() {
    let library = FakeLibraryReading()
    let model = ItemDetailModel(
      itemId: "abs-show", library: library,
      nativePodcastShowsReading: NoOpNativePodcastShowsReading())

    #expect(model.state == .loading)
    #expect(library.itemDetailSubscriberCount == 1)
  }

  @MainActor
  @Test("an unseeded item starts loading and can resolve not found")
  func unseededItemStillStartsLoadingAndResolvesNotFound() async {
    let library = FakeLibraryReading()
    let model = ItemDetailModel(
      itemId: "missing", library: library,
      nativePodcastShowsReading: NoOpNativePodcastShowsReading())

    #expect(model.state == .loading)
    library.pushItemDetail(nil)
    await waitUntil { model.state != .loading }
    #expect(model.state == .notFound)
  }

  @MainActor
  @Test("the observed stream replaces the route seed")
  func streamValueReplacesTheSeed() async {
    let library = FakeLibraryReading()
    let seed = ItemSummary(
      serverItemId: "item1", mediaKind: "book", title: "Seed", author: "Author",
      durationSeconds: 42)
    let current = ItemSummary(
      serverItemId: "item1", mediaKind: "book", title: "Current", author: "Author",
      durationSeconds: 43)
    let model = ItemDetailModel(
      itemId: "item1", seed: seed, library: library,
      nativePodcastShowsReading: NoOpNativePodcastShowsReading())

    library.pushItemDetail(current)
    await waitUntil { model.state == .loaded(current) }

    #expect(model.state == .loaded(current))
  }

  @MainActor
  @Test("starts loading and reflects the fake's first pushed value")
  func startsLoadingThenReflectsPushedValue() async {
    let library = FakeLibraryReading()
    let model = ItemDetailModel(
      itemId: "item1", library: library,
      nativePodcastShowsReading: NoOpNativePodcastShowsReading())

    #expect(model.state == .loading)

    let summary = ItemSummary(
      serverItemId: "item1", mediaKind: "book", title: "Detail Title", author: "Detail Author",
      durationSeconds: 42)
    library.pushItemDetail(summary)
    await waitUntil { model.state != .loading }

    #expect(model.state == .loaded(summary))
  }

  @MainActor
  @Test("a nil push (absent or soft-deleted) is the notFound state")
  func nilPushIsNotFoundState() async {
    let library = FakeLibraryReading()
    let model = ItemDetailModel(
      itemId: "missing", library: library,
      nativePodcastShowsReading: NoOpNativePodcastShowsReading())

    library.pushItemDetail(nil)
    await waitUntil { model.state != .loading }

    #expect(model.state == .notFound)
  }

  @MainActor
  @Test("an EPUB ebook exposes the Read action")
  func ebookCategoryOffersReadAction() async {
    let library = FakeLibraryReading()
    let reader = FakeReaderStateReading(
      state: .downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")))
    let summary = Self.summary(category: .ebook)
    let model = ItemDetailModel(
      itemId: summary.serverItemId, seed: summary, library: library,
      nativePodcastShowsReading: NoOpNativePodcastShowsReading(), readerReading: reader)

    await waitUntil { model.readAffordance == .read }

    #expect(model.readAffordance == .read)
    #expect(model.readAffordanceCopy == ReaderDetailCopy.read)
  }

  @MainActor
  @Test("only an ebook-category item offers the reader-side finish affordance")
  func readerFinishAffordanceIsEbookCategoryOnly() async {
    let readerState = ReaderState.downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub"))

    let ebookSummary = Self.summary(category: .ebook)
    let ebookModel = ItemDetailModel(
      itemId: ebookSummary.serverItemId, seed: ebookSummary, library: FakeLibraryReading(),
      nativePodcastShowsReading: NoOpNativePodcastShowsReading(),
      readerReading: FakeReaderStateReading(state: readerState))
    await waitUntil { ebookModel.readAffordance == .read }
    #expect(ebookModel.offersReaderFinish == true)

    let audiobookSummary = Self.summary(category: .audiobook)
    let audiobookModel = ItemDetailModel(
      itemId: audiobookSummary.serverItemId, seed: audiobookSummary, library: FakeLibraryReading(),
      nativePodcastShowsReading: NoOpNativePodcastShowsReading(),
      readerReading: FakeReaderStateReading(state: readerState))
    await waitUntil { audiobookModel.readAffordance == .read }
    #expect(audiobookModel.offersReaderFinish == false)
  }

  @MainActor
  @Test("an EPUB ebook with progress exposes Continue reading percentage")
  func ebookCategoryOffersContinueReadingPercentage() async {
    let library = FakeLibraryReading()
    let reader = FakeReaderStateReading(
      state: .downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")), progress: 0.42)
    let summary = Self.summary(category: .ebook)
    let model = ItemDetailModel(
      itemId: summary.serverItemId, seed: summary, library: library,
      nativePodcastShowsReading: NoOpNativePodcastShowsReading(), readerReading: reader)

    await waitUntil { model.readAffordance == .continueReading(percent: 42) }

    #expect(model.readAffordance == .continueReading(percent: 42))
    #expect(model.readAffordanceCopy == ReaderDetailCopy.continueReading(percent: 42))
  }

  @MainActor
  @Test("a bundled EPUB audiobook keeps its audio state and never offers reader finish")
  func bundledEPUBAudiobookKeepsAudioStateWithoutReaderFinish() async {
    let library = FakeLibraryReading()
    let reader = FakeReaderStateReading(
      state: .downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")), progress: 0.25)
    let summary = Self.summary(category: .audiobook)
    let model = ItemDetailModel(
      itemId: summary.serverItemId, seed: summary, library: library,
      nativePodcastShowsReading: NoOpNativePodcastShowsReading(), readerReading: reader)

    await waitUntil { model.readAffordance == .continueReading(percent: 25) }

    #expect(model.state == .loaded(summary))
    #expect(model.readAffordance == .continueReading(percent: 25))
    #expect(model.offersReaderFinish == false)
  }

  @MainActor
  @Test("a non-EPUB ebook has no Read affordance")
  func nonEPUBEbookHasNoReadAffordance() async {
    let library = FakeLibraryReading()
    // Even a stale/incorrect ready state cannot override the item's supported-format capability.
    let reader = FakeReaderStateReading(
      state: .downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/not-really-an-epub")))
    let summary = Self.summary(category: .ebook, hasReadableEbook: false)
    let model = ItemDetailModel(
      itemId: summary.serverItemId, seed: summary, library: library,
      nativePodcastShowsReading: NoOpNativePodcastShowsReading(), readerReading: reader)

    await waitUntil { model.readAffordance == .none }

    #expect(model.readAffordance == .none)
  }

  @MainActor
  @Test("an advertised EPUB with no file explains that reading is unavailable")
  func advertisedButUnavailableIsExplainedNotOffered() async {
    let library = FakeLibraryReading()
    let reader = FakeReaderStateReading(state: .advertisedButUnavailable)
    let summary = Self.summary(category: .ebook)
    let model = ItemDetailModel(
      itemId: summary.serverItemId, seed: summary, library: library,
      nativePodcastShowsReading: NoOpNativePodcastShowsReading(), readerReading: reader)

    await waitUntil { model.readAffordance == .advertisedButUnavailable }

    #expect(model.readAffordance == .advertisedButUnavailable)
    #expect(model.readAffordanceCopy == ReaderDetailCopy.advertisedButUnavailable)
  }

  @MainActor
  @Test("an EPUB available but not downloaded exposes an actionable Read action")
  func availableNotDownloadedExposesReadAction() async {
    let library = FakeLibraryReading()
    let reader = FakeReaderStateReading(state: .availableNotDownloaded)
    let summary = Self.summary(category: .ebook)
    let model = ItemDetailModel(
      itemId: summary.serverItemId, seed: summary, library: library,
      nativePodcastShowsReading: NoOpNativePodcastShowsReading(), readerReading: reader)

    await waitUntil { model.readAffordance == .read }

    #expect(model.readAffordance == .read)
    #expect(model.readAffordanceCopy == ReaderDetailCopy.read)
  }

  @MainActor
  @Test("an EPUB whose downloaded file is missing exposes an actionable Read action")
  func downloadedButFileMissingExposesReadAction() async {
    let library = FakeLibraryReading()
    let reader = FakeReaderStateReading(state: .downloadedButFileMissing)
    let summary = Self.summary(category: .ebook)
    let model = ItemDetailModel(
      itemId: summary.serverItemId, seed: summary, library: library,
      nativePodcastShowsReading: NoOpNativePodcastShowsReading(), readerReading: reader)

    await waitUntil { model.readAffordance == .read }

    #expect(model.readAffordance == .read)
    #expect(model.readAffordanceCopy == ReaderDetailCopy.read)
  }

  @MainActor
  @Test("an EPUB identity that has not been fetched keeps no Read affordance")
  func ebookIdentityNotFetchedKeepsNoReadAffordance() async {
    let library = FakeLibraryReading()
    let reader = FakeReaderStateReading(state: .ebookIdentityNotFetched)
    let summary = Self.summary(category: .ebook)
    let model = ItemDetailModel(
      itemId: summary.serverItemId, seed: summary, library: library,
      nativePodcastShowsReading: NoOpNativePodcastShowsReading(), readerReading: reader)

    await waitUntil { model.readAffordance == .none }

    #expect(model.readAffordance == .none)
  }

  @MainActor
  @Test("an EPUB download exposes its progress")
  func downloadingExposesProgress() async {
    let library = FakeLibraryReading()
    let reader = FakeReaderStateReading(state: .downloading(progress: 0.37))
    let summary = Self.summary(category: .ebook)
    let model = ItemDetailModel(
      itemId: summary.serverItemId, seed: summary, library: library,
      nativePodcastShowsReading: NoOpNativePodcastShowsReading(), readerReading: reader)

    await waitUntil { model.readAffordance == .downloading(progress: 0.37) }

    #expect(model.readAffordance == .downloading(progress: 0.37))
    #expect(model.readAffordanceCopy == ReaderDetailCopy.downloading(progress: 0.37))
  }

  /// Finishing is not a property of where the file is, so a finished downloaded book keeps a read
  /// action; the screen's own finished projection is what turns its title into "Read Again".
  @MainActor
  @Test("a finished EPUB still offers a read action")
  func finishedStillOffersAReadAction() async {
    let library = FakeLibraryReading()
    let reader = FakeReaderStateReading(
      state: .downloadedReady(fileURL: URL(fileURLWithPath: "/tmp/book.epub")), progress: 1)
    let summary = Self.summary(category: .ebook)
    let model = ItemDetailModel(
      itemId: summary.serverItemId, seed: summary, library: library,
      nativePodcastShowsReading: NoOpNativePodcastShowsReading(), readerReading: reader)

    await waitUntil { model.readAffordance == .continueReading(percent: 100) }

    #expect(
      ReaderDetailCopy.detailActionTitle(for: model.readAffordance, isFinished: true)
        == "Read Again")
  }

  @MainActor
  @Test("the model deinitializes while its observation streams remain alive")
  func modelDeinitializesWhileItsObservationStreamsRemainAlive() async {
    let library = FakeLibraryReading()
    let reader = FakeReaderStateReading(state: .noEpubAdvertised)
    weak var observer: ItemDetailModel?
    var model: ItemDetailModel?

    do {
      model = ItemDetailModel(
        itemId: "item1", library: library,
        nativePodcastShowsReading: NoOpNativePodcastShowsReading(), readerReading: reader)
      observer = model
      library.pushItemDetail(nil)
      #expect(await waitUntil { model?.state == .notFound })
      model = nil
    }

    #expect(await waitUntil { observer == nil })
  }

  private static func summary(
    category: ItemMediaCategory, hasReadableEbook: Bool = true
  ) -> ItemSummary {
    ItemSummary(
      serverItemId: "reader-item", mediaKind: "book", title: "Reader", author: "Author",
      durationSeconds: 42, category: category, hasReadableEbook: hasReadableEbook)
  }
}

private final class FakeReaderStateReading: ReaderStateReading, @unchecked Sendable {
  private let stateStream: TestStream<ReaderState>
  private let progressStream: TestStream<Double?>

  init(state: ReaderState, progress: Double? = nil) {
    stateStream = TestStream(initial: state)
    progressStream = TestStream(initial: progress)
  }

  func observeReaderState(itemId: String) -> AsyncStream<ReaderState> {
    stateStream.stream
  }

  func observeEbookProgress(itemId: String) -> AsyncStream<Double?> {
    progressStream.stream
  }
}

private final class TestStream<Value: Sendable>: @unchecked Sendable {
  let stream: AsyncStream<Value>
  private let continuation: AsyncStream<Value>.Continuation

  init() {
    var captured: AsyncStream<Value>.Continuation?
    stream = AsyncStream { captured = $0 }
    continuation = captured!
  }

  convenience init(initial: Value) {
    self.init()
    continuation.yield(initial)
  }

  func push(_ value: Value) {
    continuation.yield(value)
  }
}

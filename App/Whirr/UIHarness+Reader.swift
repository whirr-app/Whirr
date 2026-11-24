#if DEBUG || PERF_INVESTIGATION
  import AppModel
  import Foundation
  import Persistence
  import ReaderCore
  import SyncEngine

  /// Reader harness scenarios are selected with `WHIRR_UI_HARNESS_READER`. They cover the
  /// AppModel outcomes and chrome composition on both device families without parsing a real
  /// EPUB. The real Readium surface is a device acceptance concern.
  nonisolated enum UIHarnessReaderScenario: String, Sendable {
    case loading
    case downloadingFirst = "downloading-first"
    case readingWithChrome = "reading-with-chrome"
    case appearance
    case toc
    case protectedFile = "protected-file"
    case corruptFile = "corrupt-file"
    case fixedLayout = "fixed-layout-with-disabled-controls"
    case finishOffer = "finish-offer"

    static var current: Self {
      ProcessInfo.processInfo.environment["WHIRR_UI_HARNESS_READER"]
        .flatMap(Self.init(rawValue:)) ?? .readingWithChrome
    }

    /// A book long enough for the rail to read "Page 42 of 336". The page copy is only meaningful
    /// when the publication carries a positions list of that length.
    static let pageCount = 336
    /// One-based, like every other position in the reader.
    static let midBookPage = 42

    /// Chapter starts, in one-based page numbers, so the chapter list shows real page labels and
    /// exactly one current row at `midBookPage`.
    private static let chapterStarts: [(title: String, page: Int, depth: Int)] = [
      ("Cover", 1, 0),
      ("Chapter One — The Arrival", 7, 0),
      ("A Long Enough Chapter Title To Exercise Tail Truncation In The Row", 24, 1),
      ("Chapter Two — Wintering", 41, 0),
      ("Chapter Three — The Return", 120, 0),
      ("Notes", 300, 0),
    ]

    static let tocEntries = chapterStarts.map { chapter in
      TOCEntry(
        title: chapter.title, href: href(forPage: chapter.page), position: chapter.page,
        depth: chapter.depth)
    }

    static let positions: [ReadingPosition] = (1...pageCount).map { page in
      ReadingPosition(
        href: href(forPage: page),
        progression: 0,
        totalProgression: Double(page - 1) / Double(pageCount - 1),
        position: page)
    }

    static func position(atPage page: Int) -> ReadingPosition {
      positions[min(max(page, 1), pageCount) - 1]
    }

    /// The panel this scenario lands on, so a panel scenario needs no simulated tap to reach it.
    var initialPanel: ReaderPanel? {
      switch self {
      case .appearance: return .appearance
      case .toc: return .toc
      default: return nil
      }
    }

    /// The scenario's starting preferences, so the appearance panel opens with every control at a
    /// non-default value rather than all-default.
    var seededPreferences: ReaderPreferences {
      switch self {
      case .appearance:
        return ReaderPreferences(
          theme: .sepia, fontFamily: .serif, fontSizeStep: 3, lineSpacingStep: 2, marginsStep: 3,
          readingMode: .paginated, textAlignment: .justify)
      default:
        // Not `.system`: the harness must not change appearance with the host scheme mid-scenario.
        return ReaderPreferences(theme: .light)
      }
    }

    /// The chapter each page falls in, so a position's href matches its TOC entry's href.
    private static func href(forPage page: Int) -> String {
      let index =
        chapterStarts.lastIndex(where: { $0.page <= page }) ?? chapterStarts.startIndex
      return "chapter-\(index).xhtml"
    }
  }

  struct HarnessReaderStateReading: ReaderStateReading {
    let scenario: UIHarnessReaderScenario

    func observeReaderState(itemId: String) -> AsyncStream<ReaderState> {
      AsyncStream { continuation in
        guard
          itemId == UIHarnessFixtures.readerItemID || itemId == UIHarnessFixtures.mixedItemID
            || itemId == UIHarnessFixtures.ebookItemID
        else {
          continuation.finish()
          return
        }
        let fileName =
          itemId == UIHarnessFixtures.mixedItemID ? "harness-mixed.epub" : "harness-reader.epub"
        let fileURL = URL(fileURLWithPath: "/tmp/\(fileName)")
        switch scenario {
        case .loading:
          break
        case .downloadingFirst:
          continuation.yield(.availableNotDownloaded)
          let task = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard Task.isCancelled == false else { return }
            continuation.yield(.downloadedReady(fileURL: fileURL))
            continuation.finish()
          }
          continuation.onTermination = { _ in task.cancel() }
        default:
          continuation.yield(.downloadedReady(fileURL: fileURL))
          continuation.finish()
        }
      }
    }
  }

  /// Seeds the scenario's starting preferences and keeps writes in memory, so the appearance panel
  /// opens on real values and an edit survives closing and reopening the sheet.
  actor HarnessReaderPreferencesStore: ReaderPreferencesStoring {
    private var payload: String?

    init(scenario: UIHarnessReaderScenario) {
      payload = try? String(
        decoding: JSONEncoder().encode(scenario.seededPreferences), as: UTF8.self)
    }

    func fetchPreferencesJSON() async throws -> String? { payload }

    func writePreferencesJSON(_ preferencesJSON: String) async throws {
      payload = preferencesJSON
    }
  }

  struct HarnessReaderProgressAccess: ReaderProgressAccessing {
    func fetchRestoreTarget(itemID: String) async throws -> ReaderRestoreTarget? { nil }
    func write(position: ReadingPosition, itemID: String) async throws {}
    func markEbookAsFinished(itemID: String) async throws {}
  }

  @MainActor
  final class UIHarnessFakeEPUBRendering: EPUBRendering {
    private(set) var lifecycleState: EPUBRenderingLifecycleState = .stopped
    private(set) var positionUpdates: AsyncStream<ReadingPosition>
    var isSearchable = false
    var searchHits: [ReaderSearchHit] = []

    /// Commands the harness recorded, so a scenario can be asserted without a rendered page.
    private(set) var submittedPreferences: [ReaderPreferences] = []
    private(set) var goToSearchHitIDs: [String] = []
    private(set) var highlightedSearchHitID: String?
    private(set) var turns: [ReaderPageDirection] = []
    private(set) var currentPage = UIHarnessReaderScenario.midBookPage

    private let publication: OpenedEPUBPublication
    private var positionContinuation: AsyncStream<ReadingPosition>.Continuation
    private let scenario: UIHarnessReaderScenario

    init(scenario: UIHarnessReaderScenario) {
      self.scenario = scenario
      publication = OpenedEPUBPublication(
        toc: UIHarnessReaderScenario.tocEntries,
        positions: UIHarnessReaderScenario.positions,
        reflowable: scenario != .fixedLayout
      )
      var continuation: AsyncStream<ReadingPosition>.Continuation!
      positionUpdates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
        continuation = $0
      }
      positionContinuation = continuation
    }

    func start() async throws {
      lifecycleState = .ready
    }

    func open(_ request: EPUBOpenRequest) async throws -> OpenedEPUBPublication {
      switch scenario {
      case .protectedFile: throw EPUBRenderingOpenFailure.drmProtected
      case .corruptFile: throw EPUBRenderingOpenFailure.unopenable
      default: break
      }
      cancelSearchState()
      lifecycleState = .publicationOpen
      makePositionFeed()
      let continuation = positionContinuation
      // The rail, the chapter list's current row, and the finish offer all read from a position,
      // so every readable scenario opens somewhere real rather than at an unknown position.
      let opening =
        scenario == .finishOffer
        ? UIHarnessReaderScenario.position(atPage: UIHarnessReaderScenario.pageCount)
        : UIHarnessReaderScenario.position(atPage: UIHarnessReaderScenario.midBookPage)
      currentPage = opening.position ?? UIHarnessReaderScenario.midBookPage
      Task {
        try? await Task.sleep(for: .milliseconds(scenario == .finishOffer ? 300 : 50))
        continuation.yield(opening)
      }
      return publication
    }

    func close() async {
      cancelSearchState()
      positionContinuation.finish()
      lifecycleState = .ready
    }

    func stop() async {
      cancelSearchState()
      positionContinuation.finish()
      lifecycleState = .stopped
    }

    func go(to position: ReadingPosition) async throws {
      currentPage = position.position ?? currentPage
      positionContinuation.yield(position)
    }

    func go(toTotalProgression progression: Double) async throws {
      let page =
        Int((progression * Double(UIHarnessReaderScenario.pageCount - 1)).rounded()) + 1
      currentPage = page
      positionContinuation.yield(UIHarnessReaderScenario.position(atPage: page))
    }

    func search(query: String) -> AsyncThrowingStream<[ReaderSearchHit], any Error> {
      cancelSearchState()
      let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmedQuery.isEmpty == false else {
        return AsyncThrowingStream { continuation in continuation.finish() }
      }
      guard lifecycleState == .publicationOpen, isSearchable else {
        return AsyncThrowingStream { continuation in
          continuation.finish(throwing: ReaderSearchFailure.notSearchable)
        }
      }

      let hits = searchHits
      currentSearchHitIDs = Set(hits.map(\.id))
      return AsyncThrowingStream { continuation in
        if hits.isEmpty == false {
          continuation.yield(hits)
        }
        continuation.finish()
      }
    }

    func cancelSearch() async {
      cancelSearchState()
    }

    func highlightSearchHit(id: String?) async {
      highlightedSearchHitID = id
    }

    func go(toSearchHit id: String) async throws {
      guard currentSearchHitIDs.contains(id) else {
        throw ReaderSearchFailure.reading
      }
      goToSearchHitIDs.append(id)
    }

    func turnPage(_ direction: ReaderPageDirection) async -> Bool {
      turns.append(direction)
      let next = currentPage + (direction == .right ? 1 : -1)
      guard (1...UIHarnessReaderScenario.pageCount).contains(next) else { return false }
      currentPage = next
      positionContinuation.yield(UIHarnessReaderScenario.position(atPage: next))
      return true
    }

    func submit(preferences: ReaderPreferences) async throws {
      submittedPreferences.append(preferences)
    }

    private func makePositionFeed() {
      var continuation: AsyncStream<ReadingPosition>.Continuation!
      positionUpdates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) {
        continuation = $0
      }
      positionContinuation = continuation
    }

    private var currentSearchHitIDs = Set<String>()

    private func cancelSearchState() {
      currentSearchHitIDs.removeAll()
      highlightedSearchHitID = nil
    }
  }
#endif

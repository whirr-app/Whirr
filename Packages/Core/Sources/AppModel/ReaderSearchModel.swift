import Foundation
import Observation
import ReaderCore

/// The short-lived state for the reader's search sheet. Search results are kept out of
/// `ReaderModel`: they belong to the panel, and the renderer retains the locators only while the
/// current search is alive.
@MainActor
@Observable
public final class ReaderSearchModel {
  public var query: String = "" {
    didSet {
      guard query != oldValue else { return }
      queryDidChange()
    }
  }

  public private(set) var hits: [ReaderSearchHit] = []
  public private(set) var isSearching = false
  public private(set) var failure: ReaderSearchFailure?
  public private(set) var didReachHitLimit = false

  private static let debounceDuration: Duration = .milliseconds(300)
  private static let hitLimit = 500

  private let renderer: any EPUBRendering
  private let toc: [TOCEntry]

  @ObservationIgnored private var debounceTask: Task<Void, Never>?
  @ObservationIgnored private var streamTask: Task<Void, Never>?
  private var generation = GenerationFence()

  public init(renderer: any EPUBRendering, toc: [TOCEntry]) {
    self.renderer = renderer
    self.toc = toc
  }

  deinit {
    debounceTask?.cancel()
    streamTask?.cancel()
  }

  private func queryDidChange() {
    debounceTask?.cancel()
    streamTask?.cancel()
    debounceTask = nil
    streamTask = nil
    let currentGeneration = generation.advance()

    hits = []
    failure = nil
    didReachHitLimit = false

    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedQuery.isEmpty == false else {
      isSearching = false
      Task { @MainActor [weak self] in
        guard let self, self.generation.isCurrent(currentGeneration) else { return }
        await self.renderer.cancelSearch()
      }
      return
    }

    isSearching = true
    debounceTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: Self.debounceDuration)
      } catch {
        return
      }
      guard Task.isCancelled == false, let self else { return }
      guard self.generation.isCurrent(currentGeneration) else { return }
      self.beginSearch(query: trimmedQuery, generation: currentGeneration)
    }
  }

  private func beginSearch(query: String, generation: GenerationFence.Token) {
    guard self.generation.isCurrent(generation), Task.isCancelled == false else { return }

    let stream = renderer.search(query: query)
    streamTask = Task { @MainActor [weak self] in
      do {
        for try await page in stream {
          guard Task.isCancelled == false, let self else { return }
          guard self.generation.isCurrent(generation) else { return }
          if self.append(page: page) {
            break
          }
        }

        guard Task.isCancelled == false, let self else { return }
        guard self.generation.isCurrent(generation) else { return }
        self.isSearching = false
      } catch is CancellationError {
        // Query replacement and panel teardown cancel this task. Neither is a search failure.
      } catch {
        guard Task.isCancelled == false, let self else { return }
        guard self.generation.isCurrent(generation) else { return }
        self.failure = (error as? ReaderSearchFailure) ?? .reading
        self.isSearching = false
      }
    }
  }

  /// Adds one renderer page and returns whether the consumer must stop at the cap.
  private func append(page: [ReaderSearchHit]) -> Bool {
    let remaining = Self.hitLimit - hits.count
    guard remaining > 0 else {
      didReachHitLimit = true
      return true
    }

    hits.append(contentsOf: page.prefix(remaining).map(populateChapterTitle))
    guard hits.count >= Self.hitLimit else { return false }
    didReachHitLimit = true
    return true
  }

  private func populateChapterTitle(_ hit: ReaderSearchHit) -> ReaderSearchHit {
    guard hit.chapterTitle == nil else { return hit }
    return ReaderSearchHit(
      id: hit.id,
      chapterTitle: ReaderSearchHit.chapterTitle(for: hit.totalProgression, in: toc),
      before: hit.before,
      highlight: hit.highlight,
      after: hit.after,
      totalProgression: hit.totalProgression
    )
  }
}

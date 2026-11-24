import Foundation
import ReaderCore
import ReadiumNavigator
import ReadiumShared
import ReadiumStreamer

extension ReadiumEPUBRenderer {
  func search(query: String) -> AsyncThrowingStream<[ReaderSearchHit], any Error> {
    cancelSearchState()
    searchGeneration &+= 1
    let generation = searchGeneration
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

    guard trimmedQuery.isEmpty == false else {
      return AsyncThrowingStream { continuation in continuation.finish() }
    }
    guard lifecycle.state == .publicationOpen, let publication, publication.isSearchable else {
      return AsyncThrowingStream { continuation in
        continuation.finish(throwing: ReaderSearchFailure.notSearchable)
      }
    }

    return AsyncThrowingStream { continuation in
      self.searchContinuation = continuation
      let task = Task { @MainActor [weak self] in
        guard let self else { return }
        await self.runSearch(
          publication: publication,
          query: trimmedQuery,
          generation: generation,
          continuation: continuation
        )
      }
      self.searchTask = task
      // Dropping the stream stops the work but keeps this generation's locators: a consumer that
      // stops reading (the results panel dismissing itself to navigate, or a hit cap reached with
      // a full list still on screen) must still be able to jump to what it already showed.
      // `cancelSearch`, a newer search, `close`, and `stop` are what drop them.
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func cancelSearch() async {
    cancelSearchState()
  }

  func go(toSearchHit id: String) async throws {
    guard lifecycle.state == .publicationOpen, let navigator else {
      throw ReadiumEPUBRendererError.noPublication
    }
    guard let locator = searchLocators[id] else {
      throw ReadiumEPUBRendererError.navigationFailed
    }
    guard await navigator.go(to: locator, options: .none) else {
      throw ReadiumEPUBRendererError.navigationFailed
    }
  }

  func highlightSearchHit(id: String?) async {
    guard let navigator else { return }
    guard navigator.supports(decorationStyle: .highlight) else { return }

    guard let id else {
      navigator.apply(decorations: [], in: "search")
      return
    }
    guard let locator = searchLocators[id] else { return }

    navigator.apply(
      decorations: [
        Decoration(
          id: id,
          locator: locator,
          style: .highlight(tint: nil, isActive: false)
        )
      ],
      in: "search"
    )
  }

  private func runSearch(
    publication: Publication,
    query: String,
    generation: Int,
    continuation: AsyncThrowingStream<[ReaderSearchHit], any Error>.Continuation
  ) async {
    let result = await publication.search(query: query)
    guard generation == searchGeneration, Task.isCancelled == false else {
      return
    }

    switch result {
    case .failure(let error):
      continuation.finish(throwing: Self.searchFailure(from: error))
      searchTask = nil
      searchContinuation = nil

    case .success(let iterator):
      searchIterator = iterator
      defer {
        // A newer search has already replaced this state; leave its bookkeeping alone.
        if generation == searchGeneration {
          searchIterator = nil
          searchTask = nil
          searchContinuation = nil
        }
      }

      var ordinal = 0
      while Task.isCancelled == false {
        let result = await iterator.next()
        guard generation == searchGeneration, Task.isCancelled == false else { return }

        switch result {
        case .failure(let error):
          continuation.finish(throwing: Self.searchFailure(from: error))
          return

        case .success(nil):
          continuation.finish()
          return

        case .success(let collection?):
          var hits: [ReaderSearchHit] = []
          hits.reserveCapacity(collection.locators.count)
          for locator in collection.locators {
            let id = ReaderSearchHit.hitID(generation: generation, ordinal: ordinal)
            searchLocators[id] = locator
            hits.append(
              ReaderSearchHit(
                id: id,
                chapterTitle: ReaderSearchHit.chapterTitle(
                  for: locator.locations.totalProgression,
                  in: openedPublication?.toc ?? []
                ),
                before: locator.text.before ?? "",
                highlight: locator.text.highlight ?? "",
                after: locator.text.after ?? "",
                totalProgression: locator.locations.totalProgression
              )
            )
            ordinal += 1
          }
          if hits.isEmpty == false {
            continuation.yield(hits)
          }
        }
      }
    }
  }

  private static func searchFailure(from error: SearchError) -> ReaderSearchFailure {
    switch error {
    case .publicationNotSearchable:
      return .notSearchable
    case .badQuery:
      return .badQuery
    case .reading:
      return .reading
    }
  }

  func cancelSearchState() {
    searchTask?.cancel()
    searchIterator = nil
    searchTask = nil
    searchContinuation?.finish()
    searchContinuation = nil
    clearSearchHighlight()
    // Search locators retain book text through their text context. Drop them when cancellation
    // or a publication change ends the search.
    searchLocators.removeAll()
  }

  private func clearSearchHighlight() {
    guard let navigator else { return }
    guard navigator.supports(decorationStyle: .highlight) else { return }
    navigator.apply(decorations: [], in: "search")
  }
}

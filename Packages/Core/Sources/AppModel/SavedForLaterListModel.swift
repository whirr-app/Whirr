import Observation
import Persistence

/// The complete, mixed-media list behind Saved for Later's disclosure destination. Unlike Home's
/// bounded shelf projection, this observes every matching saved identity.
///
/// `filter` is settable here, and only here among the disclosure destinations: the reader curates
/// this shelf over time, so it carries its own media-type control.
@MainActor
@Observable
public final class SavedForLaterListModel {
  public enum State: Sendable, Equatable {
    case loading
    case empty
    case loaded
  }

  public private(set) var state: State = .loading
  public private(set) var entries: [SavedShelfItem] = []

  /// Swapping this re-opens the saved observation against the new category. The previous
  /// category's rows stay on screen until the replacement stream first emits, so changing the
  /// filter never flashes the loading or empty placeholder over a shelf that is about to refill.
  public var filter: MediaFilter {
    didSet {
      guard filter != oldValue else { return }
      subscribe(filter: filter)
    }
  }

  /// Optional because lightweight compositions can have no saved shelf source. The destination
  /// is then empty and opens no observation.
  private let savedShelf: (any SavedShelfReading)?
  @ObservationIgnored private var observationTask: Task<Void, Never>?
  /// Bumped per subscription so a yield that was already in flight on the retired stream cannot
  /// publish over the new filter's contents. Task cancellation alone does not close that window:
  /// a stream suspended in `for await` can deliver one more element before cancellation lands.
  @ObservationIgnored private var generation = GenerationFence()

  public init(savedShelf: (any SavedShelfReading)?, filter: MediaFilter) {
    self.savedShelf = savedShelf
    self.filter = filter

    guard savedShelf != nil else {
      state = .empty
      return
    }

    // Explicit first subscribe: `filter`'s `didSet` does not fire for the initial assignment.
    subscribe(filter: filter)
  }

  deinit {
    observationTask?.cancel()
  }

  private func subscribe(filter: MediaFilter) {
    guard let savedShelf else { return }

    observationTask?.cancel()
    let generation = generation.advance()

    let stream = savedShelf.observeSaved(filter: filter.category, limit: nil)
    observationTask = Task { [weak self] in
      for await entries in stream {
        guard let self, self.generation.isCurrent(generation) else { return }
        self.entries = entries
        self.state = entries.isEmpty ? .empty : .loaded
      }
    }
  }
}

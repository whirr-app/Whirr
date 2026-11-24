import Observation
import Persistence

/// One screen's shared Continue Listening visibility projection.
///
/// Every context menu reads this one screen-wide cache synchronously. Rows hold no per-item model
/// and start no task, so hidden membership has one database observation for the whole composition
/// scope.
@MainActor
@Observable
public final class ContinueListeningVisibilityStore {
  private var hiddenIdentities: Set<ListeningIdentity>

  @ObservationIgnored private var task: Task<Void, Never>?

  public init(library: any LibraryReading) {
    hiddenIdentities = []
    // Subscribed synchronously in `init`, not inside the `Task` below, so the first emission
    // cannot be missed.
    let stream = library.observeContinueListeningHidden()
    task = Task { [weak self] in
      for await identities in stream {
        guard let self else { return }
        // Assigned wholesale, never merged: an identity absent from the projection drops out
        // rather than arriving as an explicit "not hidden" value.
        self.hiddenIdentities = identities
      }
    }
  }

  public init(hidden: Set<ListeningIdentity>) {
    hiddenIdentities = hidden
    task = nil
  }

  deinit {
    task?.cancel()
  }

  /// Whether this exact whole-item or podcast-episode identity is hidden from Continue Listening.
  public func isHidden(_ identity: ListeningIdentity) -> Bool {
    hiddenIdentities.contains(identity)
  }

  /// Whether this row's whole-item, ABS episode or native-feed episode identity is hidden from
  /// Continue Listening.
  public func isHidden(itemID: String, episodeID: String? = nil) -> Bool {
    guard let identity = ListeningIdentity.resolving(itemID: itemID, episodeID: episodeID) else {
      return false
    }
    return isHidden(identity)
  }
}

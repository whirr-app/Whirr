import Observation
import Persistence

/// One screen's shared Saved for Later membership projection.
///
/// Every browse row and deferred context menu reads this one screen-wide cache synchronously. Rows
/// hold no per-item model and start no task, so saved membership has one database observation for
/// the whole composition scope.
@MainActor
@Observable
public final class SavedStatusStore {
  private var savedIdentities: Set<SavedShelfIdentity> = []

  /// True once the membership projection has emitted at least once, so an absent identity means
  /// "not saved" rather than "not read yet". Only a seeding caller needs this; row readers render
  /// the empty set as not saved and refresh when it fills.
  public private(set) var hasResolvedMembership = false

  @ObservationIgnored private var task: Task<Void, Never>?

  public init(savedShelf: any SavedShelfReading) {
    // Subscribed synchronously in `init`, not inside the `Task` below (as in `LibraryBrowseModel`).
    let stream = savedShelf.observeSavedIdentities()
    task = Task { [weak self] in
      for await identities in stream {
        guard let self else { return }
        // Assigned wholesale: a removed identity drops out rather than arriving as "not saved".
        self.savedIdentities = identities
        if self.hasResolvedMembership == false { self.hasResolvedMembership = true }
      }
    }
  }

  deinit {
    task?.cancel()
  }

  /// Whether this exact Saved for Later identity is present. An identity absent from the
  /// projection is not saved.
  public func isSaved(_ identity: SavedShelfIdentity) -> Bool {
    savedIdentities.contains(identity)
  }

  /// Whether this item's whole-item or episode identity is saved, resolved by
  /// `SavedShelfIdentity.resolving` so an episode under a device-owned `rss:` item is read as the
  /// `.rssEpisode` the shelf actually wrote. A native item with no episode is never saved.
  public func isSaved(itemID: String, episodeID: String? = nil) -> Bool {
    guard let identity = SavedShelfIdentity.resolving(itemID: itemID, episodeID: episodeID) else {
      return false
    }
    return isSaved(identity)
  }
}

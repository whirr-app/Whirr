import Foundation
import Observation
import SyncEngine

/// The item detail screen's series/narrator/chapter-list model. Complements `ItemDetailModel`'s
/// `ItemSummary` with the data only a live `expanded=1` fetch carries.
///
/// Loaded once from `ItemDetailExtrasAccess`; nothing is persisted, so no `ValueObservation`. The
/// fetch runs in a `Task`, not inline in `init`, so construction never blocks on network I/O.
@MainActor
@Observable
public final class ItemDetailExtrasModel {
  public enum State: Sendable, Equatable {
    case loading
    case loaded(ItemDetailExtras)
    /// The fetch failed for any reason (unauthenticated, transport, decode). The model treats
    /// them all alike: show nothing extra.
    case unavailable
  }

  public private(set) var state: State = .loading

  @ObservationIgnored private var task: Task<Void, Never>?

  public init(itemId: String, access: any ItemDetailExtrasAccess) {
    task = Task { [weak self] in
      guard let extras = await access.itemDetailExtras(itemId: itemId) else {
        self?.state = .unavailable
        return
      }
      self?.state = .loaded(extras)
    }
  }

  deinit {
    task?.cancel()
  }
}

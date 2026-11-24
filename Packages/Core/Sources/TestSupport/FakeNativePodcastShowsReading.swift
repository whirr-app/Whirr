import Foundation
import Persistence

/// `NativePodcastShowsReading`'s fake. Both observations are live: `pushShows` feeds the grid's
/// snapshot, `pushShow` feeds the subscriptions to one feed (every feed when `itemID` is omitted).
/// The latest pushed value is replayed to a later subscriber, so a test may push before the model
/// subscribes. Nothing is emitted until a test pushes, or seeds `snapshot` at init, and no stream
/// finishes.
public final class FakeNativePodcastShowsReading: NativePodcastShowsReading, @unchecked Sendable {
  public enum Call: Sendable, Equatable {
    case observeShows
    case observeShow(itemID: String)
  }

  /// Every call in order.
  public let recorder = CallRecorder<Call>(label: "FakeNativePodcastShowsReading")
  public var calls: [Call] { recorder.calls }

  /// The item id of every `observeShow` call, in order.
  public var observedItemIDs: [String] {
    calls.compactMap { call -> String? in
      if case .observeShow(let itemID) = call { return itemID }
      return nil
    }
  }

  private let showsHub: KeyedObservationHub<String, NativePodcastShowsSnapshot>
  private let showHub = KeyedObservationHub<String, ItemSummary?>()
  private static let gridKey = "shows"

  /// - Parameter snapshot: what `observeShows` starts with. `nil` leaves it silent until a test
  ///   pushes.
  public init(snapshot: NativePodcastShowsSnapshot? = nil) {
    showsHub = KeyedObservationHub(fallback: snapshot)
  }

  /// Simulates the grid's observation firing again.
  public func pushShows(_ snapshot: NativePodcastShowsSnapshot) {
    showsHub.push(snapshot, for: Self.gridKey)
  }

  /// Simulates the observation of `itemID` firing again; `nil` means the feed is not followed.
  public func pushShow(_ show: ItemSummary?, itemID: String? = nil) {
    showHub.push(show, for: itemID)
  }

  public func observeShows() -> AsyncStream<NativePodcastShowsSnapshot> {
    recorder.record(.observeShows)
    return showsHub.stream(for: Self.gridKey)
  }

  public func observeShow(itemId: String) -> AsyncStream<ItemSummary?> {
    recorder.record(.observeShow(itemID: itemId))
    return showHub.stream(for: itemId)
  }
}

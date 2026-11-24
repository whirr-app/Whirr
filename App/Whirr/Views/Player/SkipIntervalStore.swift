import Foundation
import Observation

/// The resolved pair the store publishes, compared to decide whether either direction moved.
nonisolated private struct SkipIntervals: Equatable, Sendable {
  let forward: Int
  let backward: Int
}

/// The skip-back and skip-forward intervals, republished once per change rather than once per
/// `UserDefaults` write.
///
/// `@AppStorage` invalidates its reader on `UserDefaults.didChangeNotification`, which names no key,
/// so any process write rebuilds it. Fine in the pushed settings leaves and the expanded player
/// (both exist only while on screen), not in `MiniPlayerContainerView`, persistent chrome in
/// `LibraryShellView`. This observes once and assigns only when a published value moves.
///
/// Directions are separate properties because Observation tracks per property. The published
/// value is the resolved interval displayed, so a stored value the menu can't represent settles
/// to its directional default before the view.
@MainActor
@Observable
final class SkipIntervalStore {
  static let shared = SkipIntervalStore()

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var preferenceChanges: PreferenceChanges<SkipIntervals>?

  private(set) var forwardSeconds: Int
  private(set) var backwardSeconds: Int

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let intervals = Self.intervals(in: defaults)
    self.forwardSeconds = intervals.forward
    self.backwardSeconds = intervals.backward

    let changes = PreferenceChanges(read: { [weak self] in
      MainActor.assumeIsolated { self?.currentIntervals ?? SkipIntervals(forward: 0, backward: 0) }
    })
    preferenceChanges = changes
    changes.observe(names: [UserDefaults.didChangeNotification], object: defaults, queue: .main) {
      [weak self] intervals in
      MainActor.assumeIsolated { self?.apply(intervals) }
    }
  }

  private var currentIntervals: SkipIntervals { Self.intervals(in: defaults) }

  private func apply(_ intervals: SkipIntervals) {
    if intervals.forward != forwardSeconds { forwardSeconds = intervals.forward }
    if intervals.backward != backwardSeconds { backwardSeconds = intervals.backward }
  }

  private static func intervals(in defaults: UserDefaults) -> SkipIntervals {
    SkipIntervals(
      forward: resolved(forward: true, in: defaults),
      backward: resolved(forward: false, in: defaults))
  }

  /// A missing key reads as `0`, which `resolvedSeconds` maps onto the directional default.
  private static func resolved(forward: Bool, in defaults: UserDefaults) -> Int {
    let key =
      forward
      ? SkipIntervalConfiguration.forwardStorageKey : SkipIntervalConfiguration.backwardStorageKey
    return SkipIntervalConfiguration.resolvedSeconds(defaults.integer(forKey: key), forward: forward)
  }
}

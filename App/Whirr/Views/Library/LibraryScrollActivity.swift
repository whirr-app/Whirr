import SwiftUI

/// Whether any of the Library's scroll views is still moving.
///
/// Not `@Observable` and not view state: a phase change arrives several times per fling, and
/// writing one into observed state would re-evaluate the owning screen. Callers push phases in and
/// act on the returned aggregate; nothing reads this from a `body`.
@MainActor
final class LibraryScrollActivity {
  /// One scroll view whose motion the Library defers work for. The set makes "every source is
  /// idle" the question rather than "the last phase I saw".
  enum SourceID: Hashable {
    case root
  }

  private(set) var isActive = false
  private var movingSources: Set<SourceID> = []

  /// Records a phase and returns the edge only when the aggregate changed, so callers act on edges
  /// rather than on every phase callback.
  @discardableResult
  func setScrollInteractionActive(_ phase: ScrollPhase, source: SourceID) -> Bool? {
    if Self.shouldDeferPublication(for: phase) {
      movingSources.insert(source)
    } else {
      movingSources.remove(source)
    }
    let edge = updateAggregate()
    return edge
  }

  /// Releases every source at once. Required on disappearance: a tab switched away
  /// mid-deceleration may never deliver `.idle`, and a standing deferral freezes the Library's
  /// rows until the reader scrolls again.
  @discardableResult
  func retireAllScrollSources() -> Bool? {
    movingSources.removeAll(keepingCapacity: true)
    let edge = updateAggregate()
    return edge
  }

  /// The phase mapping, matching the editorial wash provider's: a fling is a moment of tracking
  /// followed by seconds of deceleration, and an unknown future phase counts as motion because
  /// guessing "at rest" produces a hitch.
  static func shouldDeferPublication(for phase: ScrollPhase) -> Bool {
    switch phase {
    case .tracking, .interacting, .decelerating, .animating:
      true
    case .idle:
      false
    @unknown default:
      true
    }
  }

  private func updateAggregate() -> Bool? {
    let active = movingSources.isEmpty == false
    guard active != isActive else { return nil }
    isActive = active
    return active
  }
}

import Foundation

/// The order the reader dragged the Podcasts root sections into. A device preference alongside
/// `PodcastsRootSectionVisibility`: a comma-separated list of section raw values under its own key, as
/// pure string transforms shared by Settings' drag handler and `PodcastsView`.
///
/// The stored list is advisory: anything it omits (a later release's section, or a junk value) is
/// appended in `PodcastsRootSection.allCases` order, so a stale preference never hides a section.
public enum PodcastsRootSectionOrder {
  public static let storageKey = "podcasts.sectionOrder"

  public static func ordered(in stored: String) -> [PodcastsRootSection] {
    var ordered: [PodcastsRootSection] = []
    for token in stored.split(separator: ",") {
      guard let section = PodcastsRootSection(rawValue: token.trimmingCharacters(in: .whitespaces)),
        ordered.contains(section) == false
      else { continue }
      ordered.append(section)
    }
    return ordered + PodcastsRootSection.allCases.filter { ordered.contains($0) == false }
  }

  public static func stored(_ order: [PodcastsRootSection]) -> String {
    order.map(\.rawValue).joined(separator: ",")
  }

  /// `fromOffsets`/`toOffset` are SwiftUI's `onMove` arguments, so they index the list the reader
  /// sees (`ordered(in: stored)`), not `PodcastsRootSection.allCases`.
  public static func moving(
    _ stored: String,
    fromOffsets: IndexSet,
    toOffset: Int
  ) -> String {
    // Hand-rolled because `move(fromOffsets:toOffset:)` ships with SwiftUI, which this layer
    // cannot import (ARCHITECTURE.md). Same semantics: moved elements land immediately before
    // whatever was at `toOffset`.
    let order = ordered(in: stored)
    let indices = fromOffsets.filter(order.indices.contains)
    let moved = indices.map { order[$0] }
    var remaining = order.enumerated().filter { indices.contains($0.offset) == false }.map(\.element)
    let insertion = indices.reduce(min(toOffset, order.count)) { offset, index in
      index < toOffset ? offset - 1 : offset
    }
    remaining.insert(contentsOf: moved, at: max(0, min(insertion, remaining.count)))
    return self.stored(remaining)
  }

  /// Moves one section a single place, for the pointer-operable form of the drag.
  ///
  /// WCAG SC 2.5.7 asks that anything achievable by dragging also be achievable with a single
  /// pointer and no drag; edit mode's handle drag is still a drag. Lives here so the boundary
  /// behaviour is testable.
  ///
  /// A step past either end returns the list unchanged: wrapping would be a different operation
  /// under the same menu label.
  public static func stepping(_ stored: String, section: PodcastsRootSection, by offset: Int) -> String {
    let order = ordered(in: stored)
    guard let index = order.firstIndex(of: section) else { return self.stored(order) }
    let destination = index + offset
    guard order.indices.contains(destination) else { return self.stored(order) }

    var moved = order
    moved.remove(at: index)
    moved.insert(section, at: destination)
    return self.stored(moved)
  }

  /// Whether `stepping` would move the section, so a menu can disable a control that would do
  /// nothing.
  public static func canStep(_ stored: String, section: PodcastsRootSection, by offset: Int) -> Bool {
    let order = ordered(in: stored)
    guard let index = order.firstIndex(of: section) else { return false }
    return order.indices.contains(index + offset)
  }

  /// Sorts an already-filtered set of sections into the reader's order. `ordered(in:)` always
  /// returns every case, so this is a total ordering.
  public static func sorted(
    _ sections: [PodcastsRootSection],
    in stored: String
  ) -> [PodcastsRootSection] {
    let order = ordered(in: stored)
    return sections.sorted { left, right in
      (order.firstIndex(of: left) ?? 0) < (order.firstIndex(of: right) ?? 0)
    }
  }
}

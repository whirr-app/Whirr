/// The arrangement of the detail screen's actions and the role each control plays in it.
public enum ItemDetailActionLayout: Sendable, Equatable {
  public enum Control: Sendable, Equatable, Hashable {
    case chapters
    case play
    case read
  }

  case horizontal([Control])
  case stacked([Control])

  public static func resolve(
    capability: ItemMediaCapability,
    hasVisibleReadAction: Bool,
    isAccessibilitySize: Bool
  ) -> Self {
    // One canonical order (Chapters, Play, Read) derived from what the item can do, so a new
    // control or capability is wired in one place.
    guard capability != .unsupportedDocument else {
      return isAccessibilitySize ? .stacked([]) : .horizontal([])
    }
    var controls: [Control] = [.chapters]
    if capability.supportsPlayback { controls.append(.play) }
    if capability.supportsReading, hasVisibleReadAction { controls.append(.read) }

    guard isAccessibilitySize else { return .horizontal(controls) }

    // Stacked, the primary action leads: Play where the item has audio, otherwise Read.
    if let index = controls.firstIndex(where: { $0 != .chapters }) {
      controls.insert(controls.remove(at: index), at: 0)
    }
    return .stacked(controls)
  }
}

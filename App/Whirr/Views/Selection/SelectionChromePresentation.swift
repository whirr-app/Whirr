/// Pure presentation vocabulary shared by every multiselect surface.
nonisolated enum SelectionChromePresentation {
  nonisolated enum Screen: Hashable, CaseIterable {
    case libraryTitles
    case downloads
    case savedForLater
    case podcastEpisodes
    case homeContinue
    case libraryCollection

    /// Names what this screen selects. Titles the navigation bar while nothing is picked yet, and
    /// is the accessibility label of the entry control, which draws the bare verb, so VoiceOver
    /// needs the noun from here.
    var invitation: String {
      switch self {
      case .libraryTitles: return "Select Titles"
      case .downloads: return "Select Downloads"
      case .savedForLater: return "Select Saved"
      case .podcastEpisodes: return "Select Episodes"
      case .homeContinue: return "Select Items"
      case .libraryCollection: return "Select Items"
      }
    }

    /// Roots every selection control's accessibility identifier for this screen.
    var accessibilityIdentifierPrefix: String {
      switch self {
      case .libraryTitles: return "library"
      case .downloads: return "downloads"
      case .savedForLater: return "saved"
      case .podcastEpisodes: return "podcast"
      case .homeContinue: return "homeMore"
      case .libraryCollection: return "libraryCollection"
      }
    }
  }

  /// The visible label on the control that enters selection, on every screen.
  ///
  /// The bare verb; `invitation` carries the noun to VoiceOver.
  static let entryTitle = "Select"

  static func title(screen: Screen, selectedCount: Int, isWorking: Bool) -> String {
    if isWorking { return "Working…" }
    if selectedCount == 0 { return screen.invitation }
    return "\(selectedCount) Selected"
  }

  static func selectAllTitle(isEverythingSelected: Bool) -> String {
    isEverythingSelected ? "Deselect All" : "Select All"
  }

  static let doneTitle = "Done"

  nonisolated enum ActionSlot: Hashable, CaseIterable {
    case download
    case markAsFinished
    case more
    case destructive
  }

  /// The toolbar's positions come from this order; omitting a slot never changes its neighbours.
  static func renderedSlots(present: Set<ActionSlot>) -> [ActionSlot] {
    ActionSlot.allCases.filter { present.contains($0) }
  }
}

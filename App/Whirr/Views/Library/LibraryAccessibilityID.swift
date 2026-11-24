import Persistence

/// Semantic accessibility identifiers for the Library tab, mirroring `HomeAccessibilityID`'s
/// convention.
///
/// Its own namespace, not `HomeAccessibilityID.filterPicker`: Home keeps its chips, and one
/// identifier matching two screens' filters would make UI automation ambiguous.
enum LibraryAccessibilityID {
  /// The toolbar funnel. Always present, at every scroll offset.
  static let filterButton = "library.filterButton"

  /// The funnel's confirm-and-close row. It commits nothing (the rows above it already did) but
  /// is the only exit that reads as keeping the choices rather than abandoning them.
  static let applyFiltersButton = "library.applyFiltersButton"

  /// The escape hatch in the filtered-empty state. The filter persists across launches, so this is
  /// how a reader who quit while filtered gets back.
  static let clearFiltersButton = "library.clearFiltersButton"

  /// The native quick-filter's in-list no-results state.
  static let queryEmptyState = "library.queryEmpty"

  /// The regular-width replacement for the compact List's native A-Z rail.
  static let indexMenu = "library.indexMenu"

  /// One row of the Collections mode, keyed by server identity so it survives a refresh that
  /// replaces the stored rows.
  static func collectionRow(_ key: LibraryCollectionKey) -> String {
    "library.collection.\(key.kind.rawValue).\(key.serverLibraryID).\(key.serverID)"
  }

  /// The collection screen's list-level actions.
  static let collectionPlayButton = "library.collection.play"
  static let collectionAddToUpNextButton = "library.collection.addToUpNext"
  /// The footer that says where these lists are edited.
  static let collectionEditingNote = "library.collection.editingNote"

  /// The collection screen's selection extras. They root on
  /// `SelectionChromePresentation.Screen.libraryCollection`'s prefix, as the toolbar's own do.
  static let collectionPinnedDownload = "libraryCollection.pinnedDownload"
  static let collectionSelectionDownload = "libraryCollection.selection.download"
  static let collectionSelectionMarkAsFinished = "libraryCollection.selection.markAsFinished"
  static let collectionSelectionActions = "libraryCollection.selection.actions"
}

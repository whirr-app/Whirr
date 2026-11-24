/// What `AllShowsGrid` draws over an empty scroll host. Each all-shows screen maps its own model
/// state onto this; the grid never sees either model.
nonisolated enum AllShowsPlaceholder: Equatable {
  nonisolated enum Action: Equatable {
    case retry

    var label: String { "Retry" }
  }

  case loading(message: String)
  case empty(title: String, message: String, systemImage: String)
  case error(title: String, message: String, systemImage: String, action: Action)

  /// Loading and empty sit over a scroll view that may be pulled to refresh, so their copy must not
  /// intercept the drag. Error has an explicit Retry button and therefore stays interactive.
  var allowsHitTesting: Bool {
    if case .error = self { return true }
    return false
  }

  var action: Action? {
    if case .error(_, _, _, let action) = self { return action }
    return nil
  }
}

/// The reset-to-alphabetical copy, identical for both sources. Each presentation type re-exports
/// these under its own name so the screens' alert call sites, which source scans pin, keep their
/// spelling.
nonisolated enum AllShowsResetCopy {
  static let menuActionLabel = "Reset to Alphabetical"
  static let title = "Reset show order?"
  static let message = "This removes your custom order and sorts shows alphabetically."
  static let confirmLabel = "Reset Order"
  static let cancelLabel = "Cancel"
}

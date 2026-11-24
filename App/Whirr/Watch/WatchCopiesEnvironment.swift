import SwiftUI

/// The process-wide Watch copies front, read by the surfaces that offer a Watch action and by the
/// On Apple Watch screen. Optional so previews and the UI harness, which compose no Watch support,
/// hide the actions rather than requiring a model.
private struct WatchCopiesKey: EnvironmentKey {
  static let defaultValue: WatchCopies? = nil
}

extension EnvironmentValues {
  var watchCopies: WatchCopies? {
    get { self[WatchCopiesKey.self] }
    set { self[WatchCopiesKey.self] = newValue }
  }
}

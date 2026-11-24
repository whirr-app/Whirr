import Foundation

/// `@State` storage that builds its value on first use rather than at every `View.init`.
///
/// `State(initialValue: Model(deps))` in `init` builds the model on every construction of the view
/// value, and SwiftUI constructs views far more often than it keeps them. Models here subscribe
/// in `init` (`LibraryBrowseModel`) and `ItemDetailExtrasModel`/`ItemHistoryModel` start network
/// fetches, so each surplus construction opens a GRDB `ValueObservation` and real requests, with
/// only `deinit` racing to cancel.
///
/// This defers construction only; the model still subscribes synchronously in its own `init`
/// (a `.task` would change observation semantics and the determinism the tests rely on).
///
/// ```swift
/// @State private var deferred = DeferredModel<SettingsModel>()
/// private var model: SettingsModel {
///   deferred.resolve { SettingsModel(downloadPreferences: downloadPreferences, account: account) }
/// }
/// ```
///
/// Not `@Observable`: resolving happens during `body`, and a tracked mutation there would
/// invalidate the view being rendered.
@MainActor
final class DeferredModel<Value> {
  private var stored: Value?

  init() {}

  /// The stored value, building it with `make` on first call and returning that same instance on
  /// every later call.
  func resolve(_ make: () -> Value) -> Value {
    if let stored { return stored }
    let value = make()
    stored = value
    return value
  }
}

/// `DeferredModel` for a screen that needs one model per row.
///
/// Built on first `resolve(_:_:)` for a key, then reused. Not `@Observable`: resolving happens in
/// `body`. The models outlive the row's subtree, so a row can warm its model on appearing (a
/// `DisclosureGroup`'s content isn't built until it opens, leaving no first observation yield
/// when the expansion animates). They live as long as the screen: use only for a small bounded
/// key set (`DownloadsView`'s is the shows with downloads).
@MainActor
final class KeyedDeferredModels<Key: Hashable, Value> {
  private var stored: [Key: Value] = [:]

  init() {}

  /// The value for `key`, building it with `make` on the first call for that key.
  @discardableResult
  func resolve(_ key: Key, _ make: () -> Value) -> Value {
    if let stored = stored[key] { return stored }
    let value = make()
    stored[key] = value
    return value
  }
}

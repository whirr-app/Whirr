import Foundation
import Observation
import SwiftUI

/// The app appearance preference, republished once per change rather than once per `UserDefaults`
/// write.
///
/// `@AppStorage` invalidates on `UserDefaults.didChangeNotification` (no key named), so any write
/// would rebuild `LibraryShellView` and, through `Tab`'s non-escaping `@ViewBuilder`, every tab's
/// content. This assigns only when the value differs.
@MainActor
@Observable
final class AppAppearanceStore {
  /// One reader for a process-wide preference, so the value cannot be threaded through the shell
  /// only to disagree with itself in a sheet. A `static let` load, like `AppRuntime.shared`.
  static let shared = AppAppearanceStore()

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private var observer: NSObjectProtocol?

  private(set) var appearance: AppAppearance

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.appearance = Self.stored(in: defaults)
    observer = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        let next = Self.stored(in: self.defaults)
        guard next != self.appearance else { return }
        self.appearance = next
      }
    }
  }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  /// The Settings picker's selection. Writing through the store rather than through a second
  /// `@AppStorage` keeps the published value and the stored one from disagreeing for as long as it
  /// takes the notification to land on the main queue.
  var selection: Binding<AppAppearance> {
    Binding(get: { self.appearance }, set: { self.set($0) })
  }

  func set(_ next: AppAppearance) {
    guard next != appearance else { return }
    appearance = next
    defaults.set(next.rawValue, forKey: AppAppearance.storageKey)
  }

  private static func stored(in defaults: UserDefaults) -> AppAppearance {
    AppAppearance.resolved(defaults.string(forKey: AppAppearance.storageKey) ?? "")
  }
}

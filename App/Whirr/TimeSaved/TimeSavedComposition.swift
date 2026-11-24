import Foundation
import SwiftUI
import UIKit

/// The process-lifetime time-saved store. Device-owned rather than account-owned, so the figure
/// survives logout and an account switch.
@MainActor
enum TimeSavedComposition {
  /// Built on first use once protected data is available. Before the first unlock `UserDefaults`
  /// reads back empty, and a store built then would later write those zeros over the real totals.
  static var store: UserDefaultsTimeSaved? {
    if instance == nil, UIApplication.shared.isProtectedDataAvailable {
      let store = UserDefaultsTimeSaved(
        cloud: NSUbiquitousKeyValueStore.default,
        deviceID: UIDevice.current.identifierForVendor?.uuidString)
      instance = store
      observe(store)
    }
    return instance
  }

  private static var instance: UserDefaultsTimeSaved?
  private static var observers: [any NSObjectProtocol] = []

  /// Flushes on backgrounding (pause and unload flush through `PlaybackModel`), and re-reads the
  /// other devices' entries when iCloud reports a change.
  private static func observe(_ store: UserDefaultsTimeSaved) {
    let center = NotificationCenter.default
    observers = [
      center.addObserver(
        forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
      ) { [weak store] _ in
        MainActor.assumeIsolated { store?.flush() }
      },
      center.addObserver(
        forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
        object: NSUbiquitousKeyValueStore.default, queue: .main
      ) { [weak store] _ in
        MainActor.assumeIsolated { store?.refreshFromCloud() }
      },
    ]
  }
}

private struct TimeSavedKey: EnvironmentKey {
  static let defaultValue: UserDefaultsTimeSaved? = nil
}

extension EnvironmentValues {
  /// The device's time-saved store for Home and the Stats screen; nil hides the figure.
  var timeSaved: UserDefaultsTimeSaved? {
    get { self[TimeSavedKey.self] }
    set { self[TimeSavedKey.self] = newValue }
  }
}

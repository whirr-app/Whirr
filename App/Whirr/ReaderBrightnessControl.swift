import Foundation
import ReaderCore
import UIKit

@MainActor
final class SystemScreenBrightness: ReaderScreenBrightnessControlling {
  private let screen: UIScreen

  init?() {
    guard
      let screen = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first?.screen
    else { return nil }
    self.screen = screen
  }

  var brightness: Double {
    get { Double(screen.brightness) }
    set { screen.brightness = CGFloat(newValue) }
  }
}

@MainActor
final class DefaultsReaderBrightnessStore: ReaderBrightnessStoring {
  private static let storageKey = "reader.borrowedSystemBrightness"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func loadBorrowedSystemBrightness() -> Double? {
    (defaults.object(forKey: Self.storageKey) as? NSNumber)?.doubleValue
  }

  func saveBorrowedSystemBrightness(_ level: Double?) {
    if let level {
      defaults.set(level, forKey: Self.storageKey)
    } else {
      defaults.removeObject(forKey: Self.storageKey)
    }
  }
}

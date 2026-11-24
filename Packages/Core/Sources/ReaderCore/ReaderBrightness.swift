import Foundation

/// The screen whose brightness the reader borrows.
@MainActor public protocol ReaderScreenBrightnessControlling: AnyObject {
  var brightness: Double { get set }
}

/// Durable, device-local memory of a brightness the reader has borrowed but not yet given back.
/// Not part of the preferences store: this is a crash-recovery breadcrumb, not a setting,
/// and it must be readable at launch before any database is open.
@MainActor public protocol ReaderBrightnessStoring: AnyObject {
  func loadBorrowedSystemBrightness() -> Double?
  func saveBorrowedSystemBrightness(_ level: Double?)
}

/// Owns the ordering-sensitive borrow and restore protocol for reader-local screen brightness.
@MainActor public final class ReaderBrightnessController {
  private let screen: any ReaderScreenBrightnessControlling
  private let store: any ReaderBrightnessStoring

  private var borrowedSystemBrightness: Double?
  private var `override`: Double?
  private var isInReader = false
  private var hasRecoveredStrandedBrightness = false

  public init(
    screen: any ReaderScreenBrightnessControlling,
    store: any ReaderBrightnessStoring
  ) {
    self.screen = screen
    self.store = store
  }

  public var overrideLevel: Double? { `override` }

  public var isOverriding: Bool { `override` != nil }

  public func enterReader() {
    isInReader = true
  }

  public func setOverride(_ level: Double) {
    if borrowedSystemBrightness == nil {
      let currentBrightness = screen.brightness
      store.saveBorrowedSystemBrightness(currentBrightness)
      borrowedSystemBrightness = currentBrightness
    }

    let clampedLevel = min(max(level, 0.0), 1.0)
    `override` = clampedLevel
    screen.brightness = clampedLevel
  }

  public func clearOverride() {
    guard `override` != nil else { return }
    restoreBorrowedBrightness()
    store.saveBorrowedSystemBrightness(nil)
    borrowedSystemBrightness = nil
    `override` = nil
  }

  public func willResignActive() {
    guard `override` != nil else { return }
    restoreBorrowedBrightness()
  }

  public func didBecomeActive() {
    guard isInReader, let overrideLevel = `override` else { return }
    screen.brightness = overrideLevel
  }

  public func leaveReader() {
    clearOverride()
    isInReader = false
  }

  public func recoverStrandedBrightness() {
    guard hasRecoveredStrandedBrightness == false else { return }
    hasRecoveredStrandedBrightness = true

    guard let level = store.loadBorrowedSystemBrightness() else { return }
    screen.brightness = level
    store.saveBorrowedSystemBrightness(nil)
  }

  private func restoreBorrowedBrightness() {
    guard let borrowedSystemBrightness else { return }
    screen.brightness = borrowedSystemBrightness
  }
}

import Foundation

/// Screen state for Settings > Podcasts > iCloud Sync. The switch reflects the store; turning it on
/// only opens the confirmation and stays off until `confirmEnable()`. Turning it off persists at
/// once and needs no confirmation. Nothing here touches CloudKit: the service lifetime consults
/// `PodcastCloudSyncGate` after the store changes.
@MainActor
@Observable
public final class PodcastCloudSyncConsentModel {
  public private(set) var isEnabled: Bool
  public private(set) var isConfirmingEnable = false
  /// Set when the device cannot mint an install identity; the switch stays off.
  public private(set) var enableFailed = false

  private let reading: any PodcastCloudSyncConsentReading
  private let writing: any PodcastCloudSyncConsentWriting

  public init(
    reading: any PodcastCloudSyncConsentReading, writing: any PodcastCloudSyncConsentWriting
  ) {
    self.reading = reading
    self.writing = writing
    isEnabled = reading.hasConsent()
  }

  public convenience init(store: PodcastCloudSyncConsentStore) {
    self.init(reading: store, writing: store)
  }

  /// Keeps the switch honest against out-of-band changes (another screen, a cleared token).
  public func observe() async {
    for await value in reading.observeConsent() {
      isEnabled = value
    }
  }

  public func requestEnabled(_ enabled: Bool) {
    if enabled {
      guard isEnabled == false else { return }
      enableFailed = false
      isConfirmingEnable = true
    } else {
      isConfirmingEnable = false
      writing.revoke()
      isEnabled = false
    }
  }

  /// Only an open confirmation can grant; a stray call with no confirmation showing is ignored.
  public func confirmEnable() {
    guard isConfirmingEnable else { return }
    isConfirmingEnable = false
    if writing.grant() {
      isEnabled = true
    } else {
      isEnabled = false
      enableFailed = true
    }
  }

  /// Cancel and swipe dismissal are the same decision: nothing is written, the switch stays off.
  public func cancelEnable() {
    isConfirmingEnable = false
    isEnabled = reading.hasConsent()
  }

  public func dismissEnableFailure() {
    enableFailed = false
  }
}

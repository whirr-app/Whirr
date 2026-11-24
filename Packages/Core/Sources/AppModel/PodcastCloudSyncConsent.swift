import Foundation

/// Compile-time readiness of the Settings > Podcasts data destinations. Flipping one is an owner
/// decision. A hidden destination is preferred to a dead control.
public enum PodcastDataSettingsReadiness {
  public static let iCloudSync = true
  public static let backups = true
  /// The foreground-only automatic backup.
  public static let automaticBackups = true
}

/// A token that never leaves the physical installation it was minted on. The App implements it
/// with a `ThisDeviceOnly`, non-synchronizable Keychain item, which iCloud backup, encrypted
/// Finder backup and device-to-device transfer all leave behind. Consent bound to it therefore
/// cannot arrive on another device through a whole-device restore.
public protocol DeviceInstallIdentity: Sendable {
  func currentToken() -> DeviceInstallTokenRead
}

/// What a read of the install identity established. `absent` and `unreadable` must stay distinct:
/// the first is evidence about the installation, the second (before first unlock) is not.
public enum DeviceInstallTokenRead: Sendable, Equatable {
  case token(String)
  /// Readable, but no token exists and none could be created. Stored consent is cleared.
  case absent
  /// The identity could not be read at all. Consent reads as absent and nothing is changed.
  case unreadable
}

/// The defaults surface the consent store needs. Consent is not a Persistence table: it is a
/// device preference, not synced state, so it follows the `NativePodcastSubscriptionsPreference`
/// pattern over `UserDefaults`.
public protocol PodcastCloudSyncConsentDefaults: AnyObject {
  func boolValue(forKey key: String) -> Bool?
  func setBoolValue(_ value: Bool, forKey key: String)
  func stringValue(forKey key: String) -> String?
  func setStringValue(_ value: String, forKey key: String)
  func removeValue(forKey key: String)
}

extension UserDefaults: PodcastCloudSyncConsentDefaults {
  public func stringValue(forKey key: String) -> String? {
    object(forKey: key) as? String
  }

  public func setStringValue(_ value: String, forKey key: String) {
    set(value, forKey: key)
  }

  public func removeValue(forKey key: String) {
    removeObject(forKey: key)
  }
}

public protocol PodcastCloudSyncConsentReading: Sendable {
  func hasConsent() -> Bool
  func observeConsent() -> AsyncStream<Bool>
}

public protocol PodcastCloudSyncConsentWriting: Sendable {
  /// Records the explicit confirmation from the iCloud Sync consent sheet. Returns `false`, and
  /// records nothing, when no device install token is available, whether absent or unreadable.
  @discardableResult func grant() -> Bool
  /// Persists the disabled choice. Cloud data and local data are retained.
  func revoke()
}

/// Device-local, default-off consent for CloudKit podcast sync.
///
/// The stored flag is honoured only when its install token equals the current
/// `DeviceInstallIdentity` token. A mismatch (restored or migrated install) reads as no consent and
/// clears the flag, so the next enable needs the confirmation sheet again. An unreadable identity
/// is not a mismatch: it reports no consent and keeps both. The keys must stay out of
/// `ICloudSettingsSync.syncedKeys`, portable backups and cloud records.
public final class PodcastCloudSyncConsentStore: PodcastCloudSyncConsentReading,
  PodcastCloudSyncConsentWriting, @unchecked Sendable
{
  public static let consentKey = "podcasts.cloudSync.consent"
  public static let installTokenKey = "podcasts.cloudSync.consentInstallToken"

  private let lock = NSLock()
  private let defaults: any PodcastCloudSyncConsentDefaults
  private let identity: any DeviceInstallIdentity
  private var subscribers: [UUID: AsyncStream<Bool>.Continuation] = [:]

  public init(defaults: any PodcastCloudSyncConsentDefaults, identity: any DeviceInstallIdentity) {
    self.defaults = defaults
    self.identity = identity
  }

  public func hasConsent() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return readConsentLocked()
  }

  public func observeConsent() -> AsyncStream<Bool> {
    let id = UUID()
    return AsyncStream { [weak self] continuation in
      guard let self else {
        continuation.finish()
        return
      }
      lock.lock()
      subscribers[id] = continuation
      continuation.yield(readConsentLocked())
      lock.unlock()
      continuation.onTermination = { [weak self] _ in
        self?.removeSubscriber(id: id)
      }
    }
  }

  @discardableResult
  public func grant() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard case .token(let token) = identity.currentToken(), token.isEmpty == false else { return false }
    let previous = readConsentLocked()
    defaults.setStringValue(token, forKey: Self.installTokenKey)
    defaults.setBoolValue(true, forKey: Self.consentKey)
    if previous == false { broadcastLocked(true) }
    return true
  }

  public func revoke() {
    lock.lock()
    defer { lock.unlock() }
    let previous = readConsentLocked()
    defaults.setBoolValue(false, forKey: Self.consentKey)
    defaults.removeValue(forKey: Self.installTokenKey)
    if previous { broadcastLocked(false) }
  }

  /// Reads under the lock; clears a flag whose token no longer matches this installation. An
  /// unreadable identity reads as no consent but clears nothing, so a read before first unlock
  /// cannot turn sync off for good.
  private func readConsentLocked() -> Bool {
    guard defaults.boolValue(forKey: Self.consentKey) == true else { return false }
    if let stored = defaults.stringValue(forKey: Self.installTokenKey), stored.isEmpty == false {
      switch identity.currentToken() {
      case .unreadable: return false
      case .token(let current) where current == stored: return true
      case .token, .absent: break
      }
    }
    defaults.setBoolValue(false, forKey: Self.consentKey)
    defaults.removeValue(forKey: Self.installTokenKey)
    return false
  }

  private func broadcastLocked(_ value: Bool) {
    for continuation in subscribers.values {
      continuation.yield(value)
    }
  }

  private func removeSubscriber(id: UUID) {
    lock.lock()
    subscribers.removeValue(forKey: id)
    lock.unlock()
  }
}

/// The single question every cloud service lifetime asks before constructing a CloudKit engine,
/// checking an account or sending a request. Consent alone is not enough while the destination is
/// not yet ready; readiness alone is never consent.
public struct PodcastCloudSyncGate: Sendable {
  private let consent: any PodcastCloudSyncConsentReading
  private let destinationReady: Bool

  public init(
    consent: any PodcastCloudSyncConsentReading,
    destinationReady: Bool = PodcastDataSettingsReadiness.iCloudSync
  ) {
    self.consent = consent
    self.destinationReady = destinationReady
  }

  public var allowsCloudWork: Bool {
    destinationReady && consent.hasConsent()
  }
}

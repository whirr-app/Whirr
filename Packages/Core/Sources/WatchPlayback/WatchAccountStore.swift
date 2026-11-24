import ABSApi
import Foundation

public protocol WatchSettingsStoring: Sendable {
  func load() throws -> Data?
  func save(_ data: Data) throws
  func clear() throws
}

public enum WatchDeviceIdentity {
  public static let key = "watch.device.id.v1"

  public static func persistentID(defaults: UserDefaults = .standard) -> String {
    if let value = defaults.string(forKey: key), !value.isEmpty { return value }
    let value = UUID().uuidString.lowercased()
    defaults.set(value, forKey: key)
    return value
  }
}

/// Owns Watch-only token and non-secret account settings. The default token adapter uses a
/// separate device-only Keychain service with after-first-unlock accessibility; tests inject the
/// ABSApi in-memory adapter and settings adapter instead.
public actor WatchAccountStore {
  public static let keychainService = "com.remoteconcern.whirr.watch.tokens"
  public static let recordKey = "watch.account.record.v1"

  public nonisolated let tokenStore: any TokenStoring
  private let settings: any WatchSettingsStoring

  public init(tokenStore: any TokenStoring, settings: any WatchSettingsStoring) {
    self.tokenStore = tokenStore
    self.settings = settings
  }

  #if canImport(Security)
    /// The record lives in the protected store, never `UserDefaults`, so it stays off the
    /// Watch backup the paired iPhone keeps.
    public static func production(
      protectedStore: WatchProtectedFileStore = .production
    ) throws -> WatchAccountStore {
      try WatchAccountStore(
        tokenStore: KeychainTokenStore(serviceNamespace: Self.keychainService),
        settings: protectedStore.settings(forKey: recordKey))
    }
  #endif

  public func load() throws -> WatchAccountRecord? {
    try Self.decodeRecord(from: settings.load())
  }

  public func save(_ record: WatchAccountRecord) throws {
    guard let data = try? JSONEncoder().encode(record) else {
      throw WatchLibraryError.storageFailure
    }
    try settings.save(data)
  }

  /// Installs a phone-provisioned account as one transaction across the Watch Keychain and the
  /// non-secret settings record. The account namespace is checked before either
  /// store is changed so a stale Watch account cannot be silently replaced by another user.
  public func install(_ record: WatchAccountRecord, tokens: TokenPair) throws {
    let account: TokenAccount
    do {
      account = try record.tokenAccount()
    } catch {
      throw WatchLibraryError.storageFailure
    }

    let previousSettings: Data?
    let previousRecord: WatchAccountRecord?
    do {
      previousSettings = try settings.load()
      previousRecord = try Self.decodeRecord(from: previousSettings)
    } catch {
      throw WatchLibraryError.storageFailure
    }

    if let previousRecord {
      let previousAccount: TokenAccount
      do {
        previousAccount = try previousRecord.tokenAccount()
      } catch {
        throw WatchLibraryError.storageFailure
      }
      guard previousAccount == account else {
        throw WatchLibraryError.accountMismatch
      }
    }

    let previousTokens: TokenPair?
    do {
      previousTokens = try tokenStore.load(for: account)
    } catch {
      throw WatchLibraryError.storageFailure
    }

    do {
      try tokenStore.save(tokens, for: account)
      guard try tokenStore.load(for: account) == tokens else {
        throw WatchLibraryError.storageFailure
      }

      let encoded = try JSONEncoder().encode(record)
      try settings.save(encoded)
      guard try Self.decodeRecord(from: settings.load()) == record else {
        throw WatchLibraryError.storageFailure
      }
    } catch {
      // Rollback is best effort: the install must never report success after either store has
      // failed, and the old pair/settings are preferable to leaving a half-installed account.
      do {
        if let previousTokens {
          try tokenStore.save(previousTokens, for: account)
        } else {
          try tokenStore.clear(for: account)
        }
      } catch {}

      do {
        if let previousSettings {
          try settings.save(previousSettings)
        } else {
          try settings.clear()
        }
      } catch {}

      throw WatchLibraryError.storageFailure
    }
  }

  public func clearSettings() throws { try settings.clear() }

  public func clearTokens(for record: WatchAccountRecord) throws {
    try tokenStore.clear(for: record.tokenAccount())
  }

  private static func decodeRecord(from data: Data?) throws -> WatchAccountRecord? {
    guard let data else { return nil }
    guard let decoded = try? JSONDecoder().decode(WatchAccountRecord.self, from: data),
      let record = try? WatchAccountRecord(
        serverURL: decoded.serverURL, userID: decoded.userID, username: decoded.username,
        defaultLibraryID: decoded.defaultLibraryID)
    else {
      throw WatchLibraryError.storageFailure
    }
    return record
  }
}

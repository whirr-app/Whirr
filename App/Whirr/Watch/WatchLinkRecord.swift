import Foundation
import WatchProtocol

/// The last Watch status this phone confirmed for one account, persisted so the screen can say
/// when it was confirmed rather than guess from a silent probe. The caller supplies the time, so a
/// live probe answer and a Watch-pushed report record the same way.
struct WatchLinkRecord {
  struct Entry: Codable, Equatable {
    let accountIdentityHash: String
    let health: WatchLinkHealth?
    let confirmedAt: Date
    /// What the Watch said it can do. Nil means no status report has arrived for this account: a
    /// live probe answer or a completed setup confirms the link but knows nothing about the app's
    /// build. An entry stored before this key existed decodes with nil.
    let capabilities: Set<String>?

    init(
      accountIdentityHash: String, health: WatchLinkHealth?, confirmedAt: Date,
      capabilities: Set<String>? = nil
    ) {
      self.accountIdentityHash = accountIdentityHash
      self.health = health
      self.confirmedAt = confirmedAt
      self.capabilities = capabilities
    }
  }

  private static let key = "watch.link.record.v1"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// The stored status for this account, or nil when the record belongs to another account.
  func load(accountIdentityHash: String) -> Entry? {
    guard let entry = stored, entry.accountIdentityHash == accountIdentityHash else { return nil }
    return entry
  }

  /// Keeps the newest confirmation for an account. A pushed report and a delayed probe answer can
  /// arrive out of order; the older one must not overwrite the newer.
  ///
  /// Only a status report knows the Watch app's capabilities. A probe answer or a completed setup
  /// passes nil and keeps whatever the newest report stored, so confirming the link again never
  /// forgets which build the Watch runs.
  func record(
    accountIdentityHash: String, health: WatchLinkHealth?, confirmedAt: Date,
    capabilities: Set<String>? = nil
  ) {
    let existing = stored
    if let entry = existing, entry.accountIdentityHash == accountIdentityHash,
      entry.confirmedAt >= confirmedAt
    {
      // An older report still carries the only word on capabilities: a newer probe answer knows
      // none, and the Watch's throttle may never resend an unchanged report.
      guard let capabilities, capabilities != entry.capabilities else { return }
      let updated = Entry(
        accountIdentityHash: accountIdentityHash, health: entry.health,
        confirmedAt: entry.confirmedAt, capabilities: capabilities)
      guard let data = try? JSONEncoder().encode(updated) else { return }
      defaults.set(data, forKey: Self.key)
      return
    }
    let carriedCapabilities =
      capabilities
      ?? (existing?.accountIdentityHash == accountIdentityHash ? existing?.capabilities : nil)
    let entry = Entry(
      accountIdentityHash: accountIdentityHash, health: health, confirmedAt: confirmedAt,
      capabilities: carriedCapabilities)
    guard let data = try? JSONEncoder().encode(entry) else { return }
    defaults.set(data, forKey: Self.key)
  }

  /// Removes the record only when it belongs to this account, so it cannot erase the next
  /// account's confirmation.
  func clear(accountIdentityHash: String) {
    guard let entry = stored, entry.accountIdentityHash == accountIdentityHash else { return }
    defaults.removeObject(forKey: Self.key)
  }

  private var stored: Entry? {
    guard let data = defaults.data(forKey: Self.key) else { return nil }
    return try? JSONDecoder().decode(Entry.self, from: data)
  }
}

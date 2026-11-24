import Foundation
import WatchProtocol

/// Where the Watch keeps one account's `WatchABSRequestLedger` between launches. The file is fenced
/// by the account that wrote it, excluded from backup, and readable after first unlock, as the
/// download manifests are.
public struct WatchABSRequestLedgerFile: Sendable {
  public enum LoadError: Error, Equatable {
    /// Another account wrote the file; the caller starts this account's ledger afresh.
    case foreignAccount
    /// Corrupt or from another format version: no later read can succeed, so the caller starts
    /// afresh and the phone's next offer restores the requests.
    case corrupt
    /// Not readable now, as before first unlock: the caller tries again later.
    case unavailable
  }

  public let fileURL: URL
  public let accountStamp: WatchAccountStamp

  public init(fileURL: URL, accountStamp: WatchAccountStamp) {
    self.fileURL = fileURL
    self.accountStamp = accountStamp
  }

  /// `nil` when no ledger has been saved for this account.
  public func load() throws(LoadError) -> WatchABSRequestLedger? {
    do {
      return try store.load()
    } catch WatchFencedStoreError.foreignAccount {
      throw .foreignAccount
    } catch WatchFencedStoreError.io {
      throw .unavailable
    } catch {
      throw .corrupt
    }
  }

  public func save(_ ledger: WatchABSRequestLedger) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try store.save(ledger)
  }

  private var store: WatchAccountFencedJSONStore<WatchABSRequestLedger> {
    WatchAccountFencedJSONStore(location: .file(fileURL), accountStamp: accountStamp)
  }
}

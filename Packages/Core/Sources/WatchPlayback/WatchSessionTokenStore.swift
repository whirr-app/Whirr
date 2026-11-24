import ABSApi
import Foundation

/// Serializes one Watch service generation's token access. Once invalidated, the wrapper is
/// terminal: old asynchronous work cannot read, replace, or clear a newly installed pair.
final class WatchSessionTokenStore: TokenStoring, @unchecked Sendable {
  private let base: any TokenStoring
  private let lock = NSLock()
  private var invalidated = false

  init(base: any TokenStoring) {
    self.base = base
  }

  func invalidate() {
    lock.lock()
    invalidated = true
    lock.unlock()
  }

  func save(_ tokens: TokenPair, for account: TokenAccount) throws {
    lock.lock()
    defer { lock.unlock() }
    try ensureValid()
    try base.save(tokens, for: account)
  }

  func load(for account: TokenAccount) throws -> TokenPair? {
    lock.lock()
    defer { lock.unlock() }
    try ensureValid()
    return try base.load(for: account)
  }

  func clear(for account: TokenAccount) throws {
    lock.lock()
    defer { lock.unlock() }
    try ensureValid()
    try base.clear(for: account)
  }

  private func ensureValid() throws {
    guard invalidated == false else { throw WatchLibraryError.staleRequest }
  }
}

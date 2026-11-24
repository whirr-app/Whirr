import ABSApi
import Foundation
import Testing

@testable import WatchPlayback

private func sessionTokenAccount() throws -> TokenAccount {
  try TokenAccount(credentialNamespace: "watch-session-tests", userID: "user-1")
}

private func sessionTokenPair(_ suffix: String) -> TokenPair {
  TokenPair(accessToken: "access-\(suffix)", refreshToken: "refresh-\(suffix)")
}

@Test("session token store forwards live operations")
func forwardsLiveOperations() throws {
  let base = InMemoryTokenStore()
  let store = WatchSessionTokenStore(base: base)
  let account = try sessionTokenAccount()
  let pair = sessionTokenPair("one")

  try store.save(pair, for: account)
  #expect(try store.load(for: account) == pair)
  try store.clear(for: account)
  #expect(try store.load(for: account) == nil)
}

@Test("invalidation rejects reads and writes without touching the base")
func invalidationRejectsOperations() throws {
  let base = InMemoryTokenStore()
  let store = WatchSessionTokenStore(base: base)
  let account = try sessionTokenAccount()
  let oldPair = sessionTokenPair("old")
  try base.save(oldPair, for: account)

  store.invalidate()

  #expect(throws: WatchLibraryError.staleRequest) { try store.load(for: account) }
  #expect(throws: WatchLibraryError.staleRequest) { try store.save(sessionTokenPair("late"), for: account) }
  #expect(throws: WatchLibraryError.staleRequest) { try store.clear(for: account) }
  #expect(try base.load(for: account) == oldPair)
}

@Test("late old-generation operations cannot overwrite or delete a fresh pair")
func lateOldGenerationCannotTouchFreshPair() throws {
  let base = InMemoryTokenStore()
  let store = WatchSessionTokenStore(base: base)
  let account = try sessionTokenAccount()
  let oldPair = sessionTokenPair("old")
  let freshPair = sessionTokenPair("fresh")
  #expect(oldPair != freshPair)
  try store.save(oldPair, for: account)

  store.invalidate()
  try base.save(freshPair, for: account)

  #expect(throws: WatchLibraryError.staleRequest) { try store.save(oldPair, for: account) }
  #expect(throws: WatchLibraryError.staleRequest) { try store.clear(for: account) }
  #expect(try base.load(for: account) == freshPair)
}

import ABSApi
import Foundation
import Testing

@testable import WatchPlayback

// Kept: WatchPlaybackTests does not depend on TestSupport, and the Package.swift edit to add it is
// the owner's call.
private final class InstallationTokens: TokenStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [TokenAccount: TokenPair] = [:]
  private var saveFailuresRemaining: Int

  init(saveFailures: Int = 0) {
    saveFailuresRemaining = saveFailures
  }

  func save(_ tokens: TokenPair, for account: TokenAccount) throws {
    lock.lock()
    defer { lock.unlock() }
    if saveFailuresRemaining > 0 {
      saveFailuresRemaining -= 1
      throw TokenStoreError.malformedStoredTokens
    }
    values[account] = tokens
  }

  func load(for account: TokenAccount) throws -> TokenPair? {
    lock.lock()
    defer { lock.unlock() }
    return values[account]
  }

  func clear(for account: TokenAccount) throws {
    lock.lock()
    values.removeValue(forKey: account)
    lock.unlock()
  }
}

private func installationRecord(
  server: String = "https://example.test/abs", userID: String = "user-1", username: String? = "user"
) throws -> WatchAccountRecord {
  try WatchAccountRecord(
    serverURL: URL(string: server)!, userID: userID, username: username, defaultLibraryID: "books")
}

private func installationTokens(_ suffix: String) -> TokenPair {
  TokenPair(accessToken: "access-(suffix)", refreshToken: "refresh-(suffix)")
}

@Test("Watch account installation survives a fresh load")
func watchAccountInstallationSurvivesLoad() async throws {
  let settings = LockedMemorySettings()
  let tokens = InstallationTokens()
  let store = WatchAccountStore(tokenStore: tokens, settings: settings)
  let record = try installationRecord()
  let pair = installationTokens("one")

  try await store.install(record, tokens: pair)

  #expect(try await store.load() == record)
  #expect(try tokens.load(for: record.tokenAccount()) == pair)
}

@Test("same normalized account can replace its credential pair")
func sameAccountReplacement() async throws {
  let settings = LockedMemorySettings()
  let tokens = InstallationTokens()
  let store = WatchAccountStore(tokenStore: tokens, settings: settings)
  let first = try installationRecord()
  let replacement = try installationRecord(server: "https://EXAMPLE.TEST:443/abs", username: "renamed")
  let oldPair = installationTokens("old")
  let newPair = installationTokens("new")

  try await store.install(first, tokens: oldPair)
  try await store.install(replacement, tokens: newPair)

  #expect(try await store.load() == replacement)
  #expect(try tokens.load(for: replacement.tokenAccount()) == newPair)
}

@Test("different account installation is rejected without changing existing state")
func wrongAccountIsRejectedUnchanged() async throws {
  let settings = LockedMemorySettings()
  let tokens = InstallationTokens()
  let store = WatchAccountStore(tokenStore: tokens, settings: settings)
  let existing = try installationRecord()
  let foreign = try installationRecord(userID: "user-2")
  let oldPair = installationTokens("old")

  try await store.install(existing, tokens: oldPair)
  do {
    try await store.install(foreign, tokens: installationTokens("foreign"))
    Issue.record("foreign account should be rejected")
  } catch let error as WatchLibraryError {
    #expect(error == .accountMismatch)
  }

  #expect(try await store.load() == existing)
  #expect(try tokens.load(for: existing.tokenAccount()) == oldPair)
}

@Test("settings failure rolls back the previous account and credential pair")
func settingsFailureRestoresPriorPair() async throws {
  let settings = LockedMemorySettings()
  let tokens = InstallationTokens()
  let store = WatchAccountStore(tokenStore: tokens, settings: settings)
  let record = try installationRecord()
  let oldPair = installationTokens("old")
  try await store.install(record, tokens: oldPair)

  settings.failNextSave()
  do {
    try await store.install(record, tokens: installationTokens("new"))
    Issue.record("failing settings store should reject installation")
  } catch let error as WatchLibraryError {
    #expect(error == .storageFailure)
  }

  #expect(try await store.load() == record)
  #expect(try tokens.load(for: record.tokenAccount()) == oldPair)
}

@Test("token failure rolls back the previous settings and credential pair")
func tokenFailureRestoresPriorPair() async throws {
  let settings = LockedMemorySettings()
  let tokens = InstallationTokens()
  let store = WatchAccountStore(tokenStore: tokens, settings: settings)
  let record = try installationRecord()
  let oldPair = installationTokens("old")
  try await store.install(record, tokens: oldPair)

  tokens.failNextSave()
  do {
    try await store.install(record, tokens: installationTokens("new"))
    Issue.record("failing token store should reject installation")
  } catch let error as WatchLibraryError {
    #expect(error == .storageFailure)
  }

  #expect(try await store.load() == record)
  #expect(try tokens.load(for: record.tokenAccount()) == oldPair)
}

@Test("initial installation failure leaves no partial account")
func initialFailureLeavesNoPartialAccount() async throws {
  let settings = LockedMemorySettings()
  let tokens = InstallationTokens()
  let store = WatchAccountStore(tokenStore: tokens, settings: settings)
  let record = try installationRecord()

  settings.failNextSave()
  do {
    try await store.install(record, tokens: installationTokens("new"))
    Issue.record("failing settings store should reject initial installation")
  } catch let error as WatchLibraryError {
    #expect(error == .storageFailure)
  }

  #expect(try await store.load() == nil)
  #expect(try tokens.load(for: record.tokenAccount()) == nil)
}

extension InstallationTokens {
  fileprivate func failNextSave() {
    lock.lock()
    saveFailuresRemaining += 1
    lock.unlock()
  }
}

@Test("account stamp contains only stable hashes")
func accountStamp() throws {
  let account = try WatchAccountRecord(serverURL: URL(string: "https://example.test/abs")!, userID: "u1")
  let stamp = try account.authenticatedStamp()
  #expect(stamp.accountIdentityHash.count == 64)
  #expect(stamp.serverIdentityHash.count == 64)
  #expect(!stamp.accountIdentityHash.contains("example"))
}

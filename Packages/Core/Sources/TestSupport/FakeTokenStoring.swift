import ABSApi

/// `TokenStoring`'s fake: an in-memory store that records every call and can fail `save`, `load`
/// or `clear`, once or for good, for one account or for all of them. A failing `save` stores
/// nothing, so a test can prove nothing was persisted.
public final class FakeTokenStoring: TokenStoring, @unchecked Sendable {
  /// One call, in the order the fake received it.
  public enum Call: Equatable, Sendable {
    case save(TokenAccount)
    case load(TokenAccount)
    case clear(TokenAccount)
  }

  /// The error a failure throws when the test names none.
  public struct Failure: Error, Equatable, Sendable {
    public init() {}
  }

  private struct PendingFailure {
    var error: any Error
    /// The one account the failure applies to; `nil` applies it to every account.
    var account: TokenAccount?
    /// Calls left to fail; `nil` fails every matching call until the test clears it.
    var remaining: Int?
  }

  private struct State {
    var values: [TokenAccount: TokenPair]
    var saveFailure: PendingFailure?
    var loadFailure: PendingFailure?
    var clearFailure: PendingFailure?
  }

  /// Every call, in order, including one that throws.
  public let recorder = CallRecorder<Call>(label: "FakeTokenStoring")
  public var calls: [Call] { recorder.calls }

  private let state: Locked<State>

  /// - Parameters:
  ///   - tokens: the pairs the store already holds. Seeding records no call.
  ///   - saveFailure: thrown by every `save`; `nil` lets saves through.
  ///   - loadFailure: thrown by every `load`; `nil` lets loads through.
  ///   - clearFailure: thrown by every `clear`; `nil` lets clears through.
  public init(
    _ tokens: [TokenAccount: TokenPair] = [:],
    saveFailure: (any Error)? = nil,
    loadFailure: (any Error)? = nil,
    clearFailure: (any Error)? = nil
  ) {
    state = Locked(
      State(
        values: tokens,
        saveFailure: saveFailure.map { PendingFailure(error: $0) },
        loadFailure: loadFailure.map { PendingFailure(error: $0) },
        clearFailure: clearFailure.map { PendingFailure(error: $0) }))
  }

  // MARK: - Stubs and observations

  /// Stores `tokens` for `account` without recording a call.
  public func seed(_ tokens: TokenPair, for account: TokenAccount) {
    state.withValue { $0.values[account] = tokens }
  }

  /// What the store holds right now, read without recording a call.
  public var storedTokens: [TokenAccount: TokenPair] { state.value.values }

  /// Fails `save` with `error`, for `account` only (`nil`: any account) and for the next `times`
  /// calls (`nil`: every call). A `nil` `error` stops failing.
  public func stubSaveFailure(
    _ error: (any Error)?, for account: TokenAccount? = nil, times: Int? = nil
  ) {
    let failure = error.map { PendingFailure(error: $0, account: account, remaining: times) }
    state.withValue { $0.saveFailure = failure }
  }

  /// Fails `load` the way `stubSaveFailure` fails `save`.
  public func stubLoadFailure(
    _ error: (any Error)?, for account: TokenAccount? = nil, times: Int? = nil
  ) {
    let failure = error.map { PendingFailure(error: $0, account: account, remaining: times) }
    state.withValue { $0.loadFailure = failure }
  }

  /// Fails `clear` the way `stubSaveFailure` fails `save`; a failing `clear` removes nothing.
  public func stubClearFailure(
    _ error: (any Error)?, for account: TokenAccount? = nil, times: Int? = nil
  ) {
    let failure = error.map { PendingFailure(error: $0, account: account, remaining: times) }
    state.withValue { $0.clearFailure = failure }
  }

  /// The account of each `load`, in order.
  public var loadedAccounts: [TokenAccount] {
    var accounts: [TokenAccount] = []
    for case .load(let account) in calls { accounts.append(account) }
    return accounts
  }

  /// The account of each `save`, in order.
  public var savedAccounts: [TokenAccount] {
    var accounts: [TokenAccount] = []
    for case .save(let account) in calls { accounts.append(account) }
    return accounts
  }

  /// The account of each `clear`, in order.
  public var clearedAccounts: [TokenAccount] {
    var accounts: [TokenAccount] = []
    for case .clear(let account) in calls { accounts.append(account) }
    return accounts
  }

  // MARK: - TokenStoring

  public func save(_ tokens: TokenPair, for account: TokenAccount) throws {
    recorder.record(.save(account))
    if let error = takeFailure(\.saveFailure, for: account) { throw error }
    state.withValue { $0.values[account] = tokens }
  }

  public func load(for account: TokenAccount) throws -> TokenPair? {
    recorder.record(.load(account))
    if let error = takeFailure(\.loadFailure, for: account) { throw error }
    return state.value.values[account]
  }

  public func clear(for account: TokenAccount) throws {
    recorder.record(.clear(account))
    if let error = takeFailure(\.clearFailure, for: account) { throw error }
    state.withValue { $0.values.removeValue(forKey: account) }
  }

  /// The error `slot` throws for `account` now, if any, counting the call against its `times`.
  private func takeFailure(
    _ slot: WritableKeyPath<State, PendingFailure?>, for account: TokenAccount
  ) -> (any Error)? {
    state.withValue { (state: inout State) -> (any Error)? in
      guard var pending = state[keyPath: slot],
        pending.account == nil || pending.account == account
      else { return nil }
      if let remaining = pending.remaining {
        pending.remaining = remaining - 1
        state[keyPath: slot] = remaining <= 1 ? nil : pending
      }
      return pending.error
    }
  }
}

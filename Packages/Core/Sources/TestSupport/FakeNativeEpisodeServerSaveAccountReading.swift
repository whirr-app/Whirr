import SyncEngine

/// `NativeEpisodeServerSaveAccountReading`'s fake. It serves one account by default; a test swaps
/// the account (`stubAccount`), scripts it per read (`stubAccounts`), or makes every read throw
/// (`stubError`), as a signed-out device does.
public final class FakeNativeEpisodeServerSaveAccountReading:
  NativeEpisodeServerSaveAccountReading, @unchecked Sendable
{
  private struct State {
    var script: @Sendable (Int) -> NativeEpisodeServerSaveAccount
    var error: (any Error)?
    var reads = 0
    var failedReads = 0
  }

  private let state: Locked<State>

  public init(_ account: NativeEpisodeServerSaveAccount) {
    state = Locked(State(script: { _ in account }))
  }

  /// Serves `account` from the next read on.
  public func stubAccount(_ account: NativeEpisodeServerSaveAccount) {
    state.withValue { $0.script = { _ in account } }
  }

  /// Serves what `script` returns for each read, numbered from 1, so a test can replace the
  /// account after a given number of reads.
  public func stubAccounts(
    _ script: @escaping @Sendable (_ readNumber: Int) -> NativeEpisodeServerSaveAccount
  ) {
    state.withValue { $0.script = script }
  }

  /// Makes every following read throw `error`; `nil` serves the account again.
  public func stubError(_ error: (any Error)?) {
    state.withValue { $0.error = error }
  }

  /// Every `currentAccount()` call, including those that threw.
  public var readCount: Int { state.value.reads }

  /// The reads that threw the stubbed error (so a test can count reads made after removal).
  public var failedReadCount: Int { state.value.failedReads }

  public func currentAccount() async throws -> NativeEpisodeServerSaveAccount {
    let outcome = state.withValue { state -> Result<NativeEpisodeServerSaveAccount, any Error> in
      state.reads += 1
      if let error = state.error {
        state.failedReads += 1
        return .failure(error)
      }
      return .success(state.script(state.reads))
    }
    return try outcome.get()
  }
}

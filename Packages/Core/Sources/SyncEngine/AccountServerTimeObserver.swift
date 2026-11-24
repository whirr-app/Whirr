import ABSApi
import Foundation
import Persistence

/// Production `ServerDateObserving` conformance. ABSApi may not import Persistence
/// (ARCHITECTURE.md §1), so this maps a response's `TokenAccount` to the local account row and
/// persists the server-clock offset (`serverDate - receivedAt`). A non-matching `TokenAccount`
/// (account switch mid-request, or a stray test fake) is ignored.
public struct AccountServerTimeObserver: ServerDateObserving {
  private let accountDAO: AccountDAO
  private let store: ObservedServerTimeStore

  public init(database: AppDatabase) {
    accountDAO = AccountDAO(database: database)
    store = ObservedServerTimeStore(database: database)
  }

  public func observeServerDate(_ serverDate: Date, receivedAt: Date, account: TokenAccount) async {
    guard let record = try? accountDAO.fetch(), let accountId = record.id,
      let localAccount = try? record.credentialTokenAccount,
      localAccount == account
    else { return }
    _ = try? store.recordObservation(
      accountId: accountId, offsetSeconds: serverDate.timeIntervalSince(receivedAt), observedAt: receivedAt)
  }
}

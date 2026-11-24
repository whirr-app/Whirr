import ABSApi
import Foundation
import Persistence

/// Owns the one `OutboxDrainer` a signed-in account's drain triggers share.
///
/// Every serialisation guarantee `OutboxDrainer` documents is instance state (the per-entity
/// `drainingEntityKeys`, the per-operation in-flight set, `drainLocalSessionUploads`'s coalescing
/// flag), which `SyncEngine.triggerLocalSessionUploadDrain` and `PlaybackSessionCoordinator`'s
/// `requestDrain` rely on. A fresh drainer per trigger would give each guard an empty set and let
/// co-incident triggers run concurrent passes over one entity queue.
///
/// Account resolution is lazy (the graph is composed before login completes): read at trigger
/// time, with the drainer cached until the account changes (login, logout, server switch).
public actor OutboxDrainRequester {
  /// The seam tests use to count constructions; production supplies the real drainer.
  typealias DrainerFactory = @Sendable (TokenAccount, Int64) -> OutboxDrainer

  private let accountDAO: AccountDAO
  /// The account the client was bound to, if any. A requester can outlive that account, and a
  /// drain of the next account's rows would move them through `sending`, counting an attempt that
  /// the client then refuses to send.
  private let boundAccount: TokenAccount?
  private let makeDrainer: DrainerFactory
  private var cached: (account: TokenAccount, accountId: Int64, drainer: OutboxDrainer)?

  public init(
    accountDAO: AccountDAO,
    outboxStore: OutboxStore,
    database: AppDatabase,
    absClient: ABSClient,
    diagnostics: any DiagnosticsRecording = NoOpDiagnosticsRecording(),
    notifySessionGoneRecovery: @escaping @Sendable (_ itemID: String, _ episodeID: String?) async -> Void = {
      _, _ in
    }
  ) {
    self.accountDAO = accountDAO
    boundAccount = absClient.boundAccount
    makeDrainer = { account, accountId in
      OutboxDrainer(
        outboxStore: outboxStore, database: database, absClient: absClient, account: account,
        accountId: accountId, diagnostics: diagnostics,
        notifySessionGoneRecovery: notifySessionGoneRecovery)
    }
  }

  init(accountDAO: AccountDAO, makeDrainer: @escaping DrainerFactory) {
    self.accountDAO = accountDAO
    boundAccount = nil
    self.makeDrainer = makeDrainer
  }

  /// The ordinary keyed drain. A no-op when no account is signed in.
  public func drainOutbox(
    now: Date = Date(),
    randomUnit: @Sendable @escaping () -> Double = { Double.random(in: 0...1) }
  ) async {
    guard let drainer = await resolvedDrainer() else { return }
    await drainer.drainOutbox(now: now, randomUnit: randomUnit)
  }

  /// The bounded `local-all` batch drain. A no-op when no account is signed in.
  public func drainLocalSessionUploads(
    now: Date = Date(),
    randomUnit: @Sendable @escaping () -> Double = { Double.random(in: 0...1) }
  ) async {
    guard let drainer = await resolvedDrainer() else { return }
    await drainer.drainLocalSessionUploads(now: now, randomUnit: randomUnit)
  }

  private func resolvedDrainer() async -> OutboxDrainer? {
    guard let record = try? await accountDAO.fetchAsync(), let accountId = record.id,
      let account = try? record.credentialTokenAccount
    else { return nil }
    if let boundAccount, boundAccount != account { return nil }

    // Checked after the fetch, not before: co-incident triggers all suspend on that await, so a
    // pre-check alone would let each construct its own drainer. Everything from here to the
    // assignment runs without suspending, so the first resumer wins and the rest hit the cache.
    if let cached, cached.accountId == accountId, cached.account == account { return cached.drainer }

    let drainer = makeDrainer(account, accountId)
    cached = (account, accountId, drainer)
    return drainer
  }
}

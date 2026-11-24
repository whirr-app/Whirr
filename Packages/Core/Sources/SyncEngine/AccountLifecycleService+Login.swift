import ABSApi
import Foundation
import Persistence

/// First sign-in and re-login: the exchange runs through `ABSClient`, then `finishLogin` writes
/// the headers, the single account row, its endpoint, and finally the Keychain commit.
extension AccountLifecycleService {
  public func login(server: ValidatedServer, username: String, password: String) async throws {
    let credentials = LoginCredentials(username: username, password: password)
    try await logIn(server: server, method: .password) { client in
      try await client.prepareLogin(credentials: credentials)
    }
  }

  public func login(server: ValidatedServer, apiToken: String) async throws {
    let credentials = APITokenCredentials(token: apiToken)
    try await logIn(server: server, method: .apiToken) { client in
      try await client.prepareLogin(apiToken: credentials)
    }
  }

  func logIn(
    server: ValidatedServer,
    method: CredentialMethod,
    prepare: (ABSClient) async throws -> LoginSession
  ) async throws {
    let serverConfig: ABSServerConfig
    do {
      serverConfig = try serverConfigFactory.make(
        for: server.serverURL, customHeaders: server.customHeaders)
    } catch {
      throw AccountLifecycleError.malformedURL
    }

    if let retryAfter = await loginBackoffGate.admit() {
      throw AccountLifecycleError.loginRateLimited(retryAfter: retryAfter)
    }

    let client: ABSClient
    let existing: ExistingAccountState
    do {
      client = makeClient(serverConfig, tokenStore)
      existing = try existingAccountState()
    } catch {
      // Admission is a reservation. Setup failures happen before a request exists, so release
      // it without counting a server failure or clearing real backoff history.
      await loginBackoffGate.releaseReservation()
      throw Self.preAuthenticationReadFailure(error)
    }

    let session: LoginSession
    do {
      session = try await prepare(client)
    } catch {
      throw await credentialFailure(error, method: method, operation: "login", step: method.loginStep)
    }
    await loginBackoffGate.recordSuccess()

    try await finishLogin(
      session: session, client: client, server: server, existing: existing,
      signsInWithOpenID: method == .openID)
  }

  private struct ExistingAccountState: Sendable {
    let record: AccountRecord?
    let tokenAccount: TokenAccount?
    let tokens: TokenPair?
  }

  private func existingAccountState() throws -> ExistingAccountState {
    let record = try accountDAO.fetch()
    let tokenAccount = record.flatMap {
      try? $0.credentialTokenAccount
    }
    let tokens = try tokenAccount.flatMap { try tokenStore.load(for: $0) }
    return ExistingAccountState(record: record, tokenAccount: tokenAccount, tokens: tokens)
  }

  private func finishLogin(
    session: LoginSession,
    client: ABSClient,
    server: ValidatedServer,
    existing: ExistingAccountState,
    signsInWithOpenID: Bool
  ) async throws {
    if existing.tokenAccount != nil,
      existing.record != nil,
      existing.tokens == nil,
      session.userID != existing.record?.serverUserId
    {
      await client.discardLogin(session)
      Self.logger.error("login refused: this device is bound to a different account")
      throw AccountLifecycleError.deviceBoundToDifferentAccount
    }

    let previousHeaders: CustomHeaders?
    do {
      previousHeaders = try customHeaderStore.load(for: server.serverURL)
    } catch {
      await client.discardLogin(session)
      throw Self.postAuthenticationFailure(error, step: .loadCustomHeaders)
    }

    do {
      do {
        try await saveCustomHeaders(server.customHeaders, for: server.serverURL)
      } catch {
        throw Self.postAuthenticationFailure(error, step: .saveCustomHeaders)
      }
      let savedAccount: AccountRecord
      do {
        savedAccount = try saveAccountRecord(
          for: session, server: server, signsInWithOpenID: signsInWithOpenID)
      } catch {
        throw Self.postAuthenticationFailure(error, step: .saveAccountRecord)
      }
      // The endpoint row is database state, so it lands before the Keychain commit. A failure
      // here still restores the previous account row, whereas a committed token pair cannot be
      // rolled back by the catch below.
      do {
        try upsertEndpoint(for: savedAccount, serverURL: server.serverURL)
      } catch {
        throw Self.postAuthenticationFailure(error, step: .saveAccountRecord)
      }
      do {
        try await client.commitLogin(
          session, storingUnder: try savedAccount.credentialTokenAccount)
      } catch {
        throw Self.postAuthenticationFailure(error, step: .commitLogin)
      }
    } catch {
      await client.discardLogin(session)
      restoreAccountRecord(existing.record)
      await restoreCustomHeaders(previousHeaders, for: server.serverURL)
      throw error
    }
  }

  private func restoreAccountRecord(_ existing: AccountRecord?) {
    do {
      if let existing {
        _ = try accountDAO.save(existing)
      } else {
        try accountDAO.delete()
      }
    } catch {
      // Preserve the original login failure; the normal DAO transaction already keeps a failed
      // save atomic, and this best-effort restore handles the prior successful-save case.
    }
  }

  private func restoreCustomHeaders(_ previous: CustomHeaders?, for serverURL: URL) async {
    do {
      if let previous {
        try customHeaderStore.save(previous, for: serverURL)
      } else {
        try customHeaderStore.clear(for: serverURL)
      }
    } catch {
      // Preserve the original login failure while keeping restoration best effort for stores
      // whose own rollback operation can fail.
    }
  }

  private func saveCustomHeaders(_ headers: CustomHeaders, for serverURL: URL) async throws {
    let previous = try customHeaderStore.load(for: serverURL)
    try customHeaderStore.save(headers, for: serverURL)
    if (previous?.fingerprint ?? CustomHeaders.none.fingerprint) != headers.fingerprint {
      await clearCachedArtwork()
    }
  }

  private func saveAccountRecord(
    for session: LoginSession, server: ValidatedServer, signsInWithOpenID: Bool
  ) throws -> AccountRecord {
    // `existing` may be nil (first login) or a prior account (relaunch or re-login). Its
    // `clientUUID`, if any, must survive untouched.
    let existing = try accountDAO.fetch()
    let record = AccountRecord(
      id: existing?.id,
      clientUUID: existing?.clientUUID ?? generateClientUUID(),
      credentialNamespace: existing?.credentialNamespace,
      serverBaseURL: session.account.serverIdentity,
      serverUserId: session.userID,
      serverVersion: server.serverVersion,
      defaultLibraryId: session.defaultLibraryID,
      librarySelectionMode: existing?.librarySelectionMode ?? .pending,
      // Every login rewrites it, so a user on a mixed server who changes method is recorded.
      signsInWithOpenID: signsInWithOpenID
    )
    return try accountRecordSaver(record)
  }

  private func upsertEndpoint(for account: AccountRecord, serverURL: URL) throws {
    guard let accountID = account.id else {
      throw AccountLifecycleError.localPersistenceFailed
    }
    let normalizedURL = try TokenAccount.normalizedServerIdentity(from: serverURL)
    let endpoints = try accountEndpointDAO.fetchAll(accountId: accountID)
    guard endpoints.contains(where: { $0.normalizedURL == normalizedURL }) == false else { return }
    _ = try accountEndpointDAO.insert(
      accountId: accountID, normalizedURL: normalizedURL, preferred: endpoints.isEmpty)
  }
}

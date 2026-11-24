import ABSApi
import Foundation
import Persistence

/// Same-account recovery. Every variant targets the stored row: the credential is the only
/// caller-supplied input. `ABSClient.reauthenticate` persists nothing unless the returned user
/// matches, and stores the pair under the namespace account. Nothing here mutates `accountDAO`:
/// success only replaces tokens (atomic inside `ABSClient.reauthenticate`) and every failure
/// throws before touching the account row.
extension AccountLifecycleService {
  public func reauthenticate(username: String, password: String) async throws {
    let credentials = LoginCredentials(username: username, password: password)
    try await reauthenticateStoredAccount(method: .password) { client, expectedAccount in
      _ = try await client.reauthenticate(credentials: credentials, expectedAccount: expectedAccount)
    }
  }

  public func reauthenticate(apiToken: String) async throws {
    let credentials = APITokenCredentials(token: apiToken)
    try await reauthenticateStoredAccount(method: .apiToken) { client, expectedAccount in
      _ = try await client.reauthenticate(apiToken: credentials, expectedAccount: expectedAccount)
    }
  }

  func reauthenticateStoredAccount(
    method: CredentialMethod,
    exchange: (ABSClient, TokenAccount) async throws -> Void
  ) async throws {
    let (serverConfig, expectedAccount) = try storedAccountServer()

    if let retryAfter = await loginBackoffGate.admit() {
      throw AccountLifecycleError.loginRateLimited(retryAfter: retryAfter)
    }

    let client = makeClient(serverConfig, tokenStore)

    do {
      try await exchange(client, expectedAccount)
    } catch let error as ReauthenticationError {
      // Neither of these is evidence about the server: it accepted the credentials and answered
      // correctly, and the failure is ours. Release the reservation without judging the attempt.
      // Arming would block the retry the recovery copy asks for, and `recordSuccess()` would erase
      // pacing earned by genuine credential rejections.
      await loginBackoffGate.releaseReservation()
      if case .tokenPersistenceFailed(let underlying) = error {
        throw Self.postAuthenticationFailure(underlying, step: .saveRotatedTokens)
      }
      Self.logger.error("\(method.logLabel, privacy: .public) re-authentication returned a different account")
      throw AccountLifecycleError.accountMismatch
    } catch {
      throw await credentialFailure(
        error, method: method, operation: "re-authentication", step: method.reauthenticationStep)
    }
    await loginBackoffGate.recordSuccess()
  }
}

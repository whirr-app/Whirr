import ABSApi
import AppModel
import Foundation
import Persistence
import SyncEngine
import WatchProtocol

/// The attempt flow: the sign-in the person asked for, the Watch handshake, and the login that
/// produces the credential payload. Transmission and the pending payload live in
/// `WatchPhoneSetupModel+Transmit.swift`; the state they all read stays in the primary declaration.
extension WatchPhoneSetupModel {
  /// Starts one attempt from a user tap. `isBusy` flips synchronously so the controls disable in
  /// the same view update as the tap, and clears only after `completion` has observed the
  /// outcome.
  func submit(password: String, completion: @escaping @MainActor (_ connected: Bool) -> Void = { _ in }) {
    start(.password(password), completion: completion)
  }

  /// `submit(password:)` for an `.openID` account.
  func submitSingleSignOn(
    using browser: any SingleSignOnBrowsing, completion: @escaping @MainActor (_ connected: Bool) -> Void = { _ in }
  ) {
    start(.singleSignOn(browser), completion: completion)
  }

  func start(_ entry: CredentialEntry, completion: @escaping @MainActor (_ connected: Bool) -> Void) {
    isBusy = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      await self.connect(entry)
      completion(self.connected)
      self.isBusy = false
    }
  }

  func connect(password: String) async {
    await connect(.password(password))
  }

  /// Sends a pending credential payload again when delivery was ambiguous. Whatever was entered is
  /// ignored in this path; no second login or fresh credential pair is created.
  func connect(_ entry: CredentialEntry) async {
    guard !connectInFlight else { return }
    connectInFlight = true
    connected = false
    error = nil
    message = nil
    defer { connectInFlight = false }
    guard let account, let reading else {
      fail(WatchSetupCopy.signInRequired)
      return
    }
    refreshInstallState()
    switch installState {
    case .unpaired:
      fail(WatchSetupCopy.notPaired)
      return
    case .appNotInstalled:
      fail(WatchSetupCopy.appNotInstalled)
      return
    case .unknown, .ready:
      break
    }
    let token = setupAttemptEpoch
    guard let url = URL(string: account.serverBaseURL), url.host != nil else {
      fail(WatchSetupCopy.invalidServer)
      return
    }
    let stamp: WatchAccountStamp
    do { stamp = try Self.accountStamp(for: account) } catch {
      fail(WatchSetupCopy.unverifiableAccount)
      return
    }

    if let attempt, let pendingPayload = attempt.payload, attempt.accountStamp == stamp {
      await resendPending(
        pendingPayload, attempt: attempt, token: token, account: account, stamp: stamp)
      return
    }

    releasePendingCredentials()
    guard username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
      fail(WatchSetupCopy.missingProfileUsername)
      return
    }
    do {
      try await performSetup(
        entry, url: url, stamp: stamp, token: token, account: account, reading: reading)
    } catch let failure as SetupFailure {
      guard token == setupAttemptEpoch else { return }
      fail(failure.message)
    } catch let failure as OIDCLoginError {
      guard token == setupAttemptEpoch else { return }
      fail(SetupFlowCopy.singleSignOnMessage(for: SingleSignOnFailure(failure)).text)
    } catch let failure as AccountLifecycleError {
      guard token == setupAttemptEpoch else { return }
      fail(SetupFlowCopy.recoveryMessage(for: failure).text)
    } catch {
      guard token == setupAttemptEpoch else { return }
      fail(WatchSetupCopy.failed)
    }
  }

  /// Retries the payload the Watch may already hold, without a new login or credential pair.
  func resendPending(
    _ pendingPayload: Data, attempt: WatchSetupAttempt, token: Int, account: AccountRecord,
    stamp: WatchAccountStamp
  ) async {
    guard attempt.isUsable(now: now()) else {
      releasePendingCredentials()
      fail(WatchSetupCopy.expired)
      return
    }
    state = .waitingForReceipt
    progress = 0.8
    await transmit(
      pendingPayload, key: WatchTransportKey.setupCredentials, token: token,
      account: account, stamp: stamp, cleanup: nil)
  }

  /// One fresh attempt: settings, any single sign-on, then the Watch handshake, then the login and
  /// the credential payload. Each phase ends the attempt the same way the single method did.
  func performSetup(
    _ entry: CredentialEntry,
    url: URL,
    stamp: WatchAccountStamp,
    token: Int,
    account: AccountRecord,
    reading: any ServerAccountReading
  ) async throws {
    guard
      let session = try await establishSession(
        entry, url: url, stamp: stamp, token: token, account: account, reading: reading)
    else { return }

    guard
      let login = try await resolveLogin(
        session.signedIn, entry: entry, url: url, token: token, account: account)
    else { return }

    let expectedServer = try TokenAccount.normalizedServerIdentity(from: url)
    guard login.userID == account.serverUserId,
      login.serverIdentity == expectedServer,
      !login.accessToken.isEmpty,
      !login.refreshToken.isEmpty
    else {
      await login.cleanup(true)
      throw SetupFailure.accountMismatch
    }

    let payload = try await encodeCredentials(
      login, hello: session.hello, challenge: session.challenge, stamp: stamp,
      expectedServer: expectedServer)
    attempt = WatchSetupAttempt(hello: session.hello, challenge: session.challenge, payload: payload)
    pendingCleanup = login.cleanup
    state = .waitingForReceipt
    progress = 0.8
    await transmit(
      payload, key: WatchTransportKey.setupCredentials, token: token,
      account: account, stamp: stamp, cleanup: login.cleanup)
  }

  /// Reads the settings the Watch handshake needs and, for an `.openID` account, signs in before
  /// the Watch's challenge window opens. Nil when the attempt already ended.
  func establishSession(
    _ entry: CredentialEntry,
    url: URL,
    stamp: WatchAccountStamp,
    token: Int,
    account: AccountRecord,
    reading: any ServerAccountReading
  ) async throws -> (hello: WatchSetupHello, challenge: WatchSetupChallenge, signedIn: LoginResult?)? {
    let settings = try await reading.readDurableSettings()
    guard token == setupAttemptEpoch, self.account == account else { return nil }
    guard settings.customHeaders.names.isEmpty else {
      fail(WatchSetupCopy.customHeadersUnsupported)
      return nil
    }

    let signIn = try await signInIfNeeded(entry, url: url, token: token, account: account)
    guard signIn.proceed else { return nil }
    let signedIn = signIn.login

    let handshake: (hello: WatchSetupHello, challenge: WatchSetupChallenge)?
    do {
      handshake = try await self.handshake(stamp: stamp, token: token, account: account)
    } catch {
      await signedIn?.cleanup(true)
      throw error
    }
    guard let (hello, challenge) = handshake else {
      await signedIn?.cleanup(true)
      return nil
    }
    return (hello, challenge, signedIn)
  }

  /// Signs in through the identity provider when the account needs it. A closed browser ends the
  /// attempt quietly, as does a stale account, which cleans up the pair it just minted.
  func signInIfNeeded(
    _ entry: CredentialEntry, url: URL, token: Int, account: AccountRecord
  ) async throws -> (proceed: Bool, login: LoginResult?) {
    guard case .singleSignOn(let browser) = entry else { return (true, nil) }
    state = .connecting
    progress = 0.05
    guard let login = try await loginProvider(url, .singleSignOn(browser), InMemoryTokenStore()) else {
      // A closed browser is not a failure: back to the button, silently.
      guard token == setupAttemptEpoch, self.account == account else { return (false, nil) }
      state = .ready
      progress = 0
      return (false, nil)
    }
    guard token == setupAttemptEpoch, self.account == account else {
      await login.cleanup(true)
      return (false, nil)
    }
    return (true, login)
  }

  /// The pair the Watch will hold: the single sign-on result, or a password login through the
  /// shared backoff gate. Nil when the account moved while the pair was being minted.
  func resolveLogin(
    _ signedIn: LoginResult?, entry: CredentialEntry, url: URL, token: Int, account: AccountRecord
  ) async throws -> LoginResult? {
    let login: LoginResult
    if let signedIn {
      login = signedIn
    } else {
      guard case .password(let password) = entry else { throw SetupFailure.accountMismatch }
      let credentials = LoginCredentials(
        username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
      defer { credentials.releasePassword() }
      if let retryAfter = await loginBackoffGate.admit() {
        throw AccountLifecycleError.loginRateLimited(retryAfter: retryAfter)
      }
      let result: LoginResult?
      do {
        result = try await loginProvider(url, .password(credentials), InMemoryTokenStore())
      } catch {
        await loginBackoffGate.recordFailure()
        throw error
      }
      await loginBackoffGate.recordSuccess()
      guard let result else { throw SetupFailure.accountMismatch }
      login = result
    }
    guard token == setupAttemptEpoch, self.account == account else {
      await login.cleanup(true)
      return nil
    }
    return login
  }
}

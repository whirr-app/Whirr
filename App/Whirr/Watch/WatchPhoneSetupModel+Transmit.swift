import ABSApi
import AppModel
import Foundation
import Persistence
import SyncEngine
import WatchProtocol

/// Building and sending the credential payload, and the pending-attempt state around it: the
/// payload is kept only until the Watch's receipt says it can be released. The attempt flow that
/// calls these lives in `WatchPhoneSetupModel+Attempt.swift`.
extension WatchPhoneSetupModel {
  /// The credential payload for the Watch's challenge. A payload that cannot be built releases the
  /// pair it was minted from.
  func encodeCredentials(
    _ login: LoginResult,
    hello: WatchSetupHello,
    challenge: WatchSetupChallenge,
    stamp: WatchAccountStamp,
    expectedServer: String
  ) async throws -> Data {
    do {
      let setupCredentials = try WatchSetupCredentials(
        id: hello.id,
        accountStamp: stamp,
        nonce: challenge.nonce,
        expiresAt: challenge.expiresAt,
        serverURL: expectedServer,
        userID: login.userID,
        username: username.trimmingCharacters(in: .whitespacesAndNewlines),
        defaultLibraryID: login.defaultLibraryID,
        accessToken: login.accessToken,
        refreshToken: login.refreshToken,
        accessExpiry: login.accessExpiry)
      return try WatchWireCodec.encode(setupCredentials)
    } catch {
      await login.cleanup(true)
      throw error
    }
  }

  /// Hello and challenge: the Watch agrees to receive one credential payload for this account.
  /// Nil when the attempt already ended, with its message shown if it was this attempt's to show.
  func handshake(
    stamp: WatchAccountStamp, token: Int, account: AccountRecord
  ) async throws -> (hello: WatchSetupHello, challenge: WatchSetupChallenge)? {
    let currentTime = now()
    let hello: WatchSetupHello
    if let attempt, attempt.accountStamp == stamp,
      attempt.isUsable(now: currentTime)
    {
      hello = attempt.hello
    } else {
      hello = try WatchSetupHello(id: UUID(), accountStamp: stamp, issuedAt: currentTime)
      attempt = WatchSetupAttempt(hello: hello)
    }
    let helloPayload = try WatchWireCodec.encode(hello)
    state = .connecting
    progress = 0.15
    guard let challengeData = await sender(helloPayload, WatchTransportKey.setupHello) else {
      guard token == setupAttemptEpoch, self.account == account else { return nil }
      fail(WatchSetupCopy.watchUnavailable)
      return nil
    }
    guard token == setupAttemptEpoch, self.account == account else { return nil }
    let challenge = try WatchWireCodec.decode(WatchSetupChallenge.self, from: challengeData)
    guard challenge.id == hello.id, challenge.accountStamp == stamp else { throw SetupFailure.invalidChallenge }
    if challenge.status == .wrongAccount {
      // As definitive as the probe's answer: no reconnect from here can replace another account.
      lastProbe = .otherAccount
      wantsReconnect = false
      fail(WatchSetupCopy.wrongAccount)
      return nil
    }
    if challenge.status == .busy {
      fail(WatchSetupCopy.busy)
      return nil
    }
    guard challenge.status == .ready,
      WatchSetupAttempt(hello: hello, challenge: challenge).isUsable(now: now())
    else { throw SetupFailure.invalidChallenge }
    return (hello, challenge)
  }

  func transmit(
    _ payload: Data,
    key: String,
    token: Int,
    account: AccountRecord,
    stamp: WatchAccountStamp,
    cleanup: (@MainActor (_ remote: Bool) async -> Void)?
  ) async {
    guard let attempt, attempt.accountStamp == stamp, attempt.isUsable(now: now()) else {
      releasePendingCredentials()
      fail(WatchSetupCopy.expired)
      return
    }
    guard let responseData = await sender(payload, key) else {
      guard token == setupAttemptEpoch else { return }
      message = WatchSetupCopy.installing
      state = .waitingForReceipt
      return
    }
    guard token == setupAttemptEpoch, self.account == account else { return }
    do {
      let receipt = try WatchWireCodec.decode(WatchSetupReceipt.self, from: responseData)
      guard let challenge = attempt.challenge,
        receipt.id == challenge.id,
        receipt.accountStamp == stamp,
        receipt.nonce == challenge.nonce
      else {
        message = WatchSetupCopy.invalidReceipt
        state = .waitingForReceipt
        return
      }
      if attempt.preservesPayload(after: receipt.status) {
        message = WatchSetupCopy.processing
        state = .waitingForReceipt
        return
      }
      guard receipt.status == .installed else {
        await (cleanup ?? pendingCleanup)?(true)
        guard token == setupAttemptEpoch, self.account == account else { return }
        clearPending(keepingHello: true)
        fail(WatchSetupCopy.rejected)
        return
      }
      await (cleanup ?? pendingCleanup)?(false)
      guard token == setupAttemptEpoch, self.account == account else { return }
      clearPending()
      connected = true
      confirmWatchLink(health: nil, for: stamp.accountIdentityHash)
      // Fresh credentials: the old pair's verdict no longer applies, and the Watch has not yet
      // asked its server with the new one.
      lastProbe = .installed(nil)
      wantsReconnect = false
      progress = 1
      message = WatchSetupCopy.connected
      error = nil
      state = .connected
    } catch {
      // A malformed or mismatched response is ambiguous because the Watch may have installed
      // credentials before its reply was lost. Keep the exact payload for an explicit retry.
      message = WatchSetupCopy.unclear
      state = .waitingForReceipt
    }
  }

  func clearPending(keepingHello: Bool = false) {
    attempt = keepingHello ? attempt?.cleared() : nil
    pendingCleanup = nil
  }

  func releasePendingCredentials() {
    let cleanup = pendingCleanup
    pendingCleanup = nil
    attempt = attempt?.cleared()
    guard let cleanup else { return }
    Task { @MainActor in await cleanup(false) }
  }

  func fail(_ text: String) {
    error = text
    message = nil
    state = .failed
    progress = 0
  }
}

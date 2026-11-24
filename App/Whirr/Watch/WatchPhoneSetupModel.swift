import ABSApi
import AppModel
import Foundation
import Observation
import Persistence
import SyncEngine
import WatchProtocol

/// The phone-side state for the one-time Apple Watch setup flow. Passwords and token pairs are
/// are kept in local variables and never published or persisted by this model.
@MainActor
@Observable
final class WatchPhoneSetupModel {
  enum State: Equatable {
    case idle
    case loadingProfile
    case ready
    case connecting
    case waitingForReceipt
    case connected
    case failed
  }

  struct LoginResult: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let userID: String
    let serverIdentity: String
    let defaultLibraryID: String?
    let accessToken: String
    let refreshToken: String
    let accessExpiry: Date?
    let cleanup: @MainActor (_ remote: Bool) async -> Void

    var description: String { "WatchPhoneSetupModel.LoginResult(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }

    init(
      userID: String,
      serverIdentity: String,
      defaultLibraryID: String?,
      accessToken: String,
      refreshToken: String,
      accessExpiry: Date?,
      cleanup: @escaping @MainActor (_ remote: Bool) async -> Void
    ) {
      self.userID = userID
      self.serverIdentity = serverIdentity
      self.defaultLibraryID = defaultLibraryID
      self.accessToken = accessToken
      self.refreshToken = refreshToken
      self.accessExpiry = accessExpiry
      self.cleanup = cleanup
    }
  }

  typealias Sender = @MainActor (Data, String) async -> Data?
  /// What the user gave to sign the Watch in.
  enum CredentialEntry {
    case password(String)
    /// An `.openID` account mints the Watch's own pair through a second, ephemeral sign-in at the
    /// identity provider. Handing over the phone's pair would leave both devices rotating one
    /// refresh token.
    case singleSignOn(any SingleSignOnBrowsing)
  }

  /// How `LoginProvider` signs in: the password copied into releasable credentials, or a browser.
  enum LoginMethod {
    case password(LoginCredentials)
    case singleSignOn(any SingleSignOnBrowsing)
  }

  /// Returns nil only when the user closed the single-sign-on browser.
  typealias LoginProvider = @MainActor (URL, LoginMethod, InMemoryTokenStore) async throws -> LoginResult?
  typealias InstallStateReader = @MainActor () -> WatchInstallState

  /// Setup always uses the signed-in phone profile; the account is never edited in this flow.
  private(set) var username = ""
  private(set) var usernameIsVerified = false
  var state: State = .idle
  var error: String?
  var message: String?
  var progress: Double = 0
  /// Stays false for the whole of a reconnect attempt while `state` may still read `.connected`
  /// until that attempt transitions it, so it is not derivable from `state`.
  var connected = false
  /// True while the phone is asking the Watch whether it is already provisioned. The view offers
  /// no password field during this, so a connected Watch never flashes a credential prompt.
  private(set) var isCheckingConnection = false
  /// The last status the Watch confirmed for this account, from a live answer or the stored
  /// record. Drives the screen's "Confirmed …" line; nil means nothing has confirmed the link.
  private(set) var lastConfirmed: WatchLinkConfirmation?
  /// True while WatchConnectivity reports the Watch reachable. The screen checks again on a
  /// false-to-true change while it is visible; nothing polls.
  private(set) var isWatchReachable = false
  /// The probe's last answer since bind. Health from an earlier process is not a live answer;
  /// `lastConfirmed` dates it instead.
  var lastProbe: WatchProbeOutcome = .none
  /// The person chose to re-provision a Watch that already holds this account, so the screen
  /// shows the setup form until they connect or cancel.
  var wantsReconnect = false
  /// True from the tap that starts an attempt until its completion handling has run; the view
  /// disables its controls and shows progress from this rather than a view-local flag.
  var isBusy = false
  private(set) var title = WatchSetupCopy.title
  private(set) var server = ""
  /// The paired-Watch prerequisite as last read from the transport. `.unknown` never blocks an
  /// attempt: it means the transport cannot yet assert anything, not that a prerequisite failed.
  private(set) var installState: WatchInstallState = .unknown
  /// The account the Watch's latest status report named, against the bound one.
  private(set) var reportedAccount: WatchReportedAccount = .unknown

  // What the screen reads (`linkStatus`, its copy, `isBlockedOnInstall`) lives in
  // `WatchPhoneSetupModel+Presentation.swift`; the attempt flow is in
  // `WatchPhoneSetupModel+Attempt.swift` and its payload in `+Transmit.swift`; this file keeps the
  // state they share.

  func beginReconnect() {
    guard linkStatus.offersReconnect || linkStatus == .signInRejected else { return }
    wantsReconnect = true
  }

  func cancelReconnect() {
    guard !isBusy, !connectInFlight else { return }
    wantsReconnect = false
  }

  let sender: Sender
  let now: @MainActor () -> Date
  let loginProvider: LoginProvider
  /// Paces the password login (API-CONVENTIONS rule 5a). In memory, like setup's gate.
  let loginBackoffGate: LoginBackoffGate
  private let readInstallState: InstallStateReader
  private let defaults: UserDefaults
  private let record: WatchLinkRecord
  private(set) var account: AccountRecord?
  var reading: (any ServerAccountReading)?
  var setupAttemptEpoch = 0
  var attempt: WatchSetupAttempt?
  var pendingCleanup: (@MainActor (_ remote: Bool) async -> Void)?
  var connectInFlight = false

  init(
    sender: @escaping Sender,
    now: @escaping @MainActor () -> Date = { Date() },
    loginProvider: LoginProvider? = nil,
    installState: @escaping InstallStateReader = { .unknown },
    defaults: UserDefaults = .standard,
    record: WatchLinkRecord? = nil,
    loginBackoffGate: LoginBackoffGate = LoginBackoffGate()
  ) {
    self.sender = sender
    self.now = now
    self.loginProvider = loginProvider ?? Self.liveLogin
    self.loginBackoffGate = loginBackoffGate
    readInstallState = installState
    self.defaults = defaults
    self.record = record ?? WatchLinkRecord(defaults: defaults)
  }

  /// Re-reads the transport prerequisite. Safe to call from the view's `task` and from the
  /// transport's own watch-state callback, so instructions clear the moment an install lands.
  func refreshInstallState() {
    installState = readInstallState()
  }

  /// WatchConnectivity reports whether the Watch can answer a live message. The setup screen
  /// reacts to the false-to-true edge while it is visible; this method only publishes the fact.
  func watchReachabilityChanged(isReachable: Bool) {
    self.isWatchReachable = isReachable
  }

  /// Asks the Watch whether it already holds a usable account for this stamp. The challenge
  /// exchange only reports whether a new attempt may start, so without this the screen invites a
  /// re-provision that logs the Watch out remotely and drains its downloads for no reason.
  func refreshConnectionStatus() async {
    // `.connected` is admitted so Check Now still works after a reconnect in this process.
    guard !connectInFlight, !isCheckingConnection, let account,
      state == .ready || state == .idle || state == .failed || state == .connected
    else { return }
    guard let stamp = try? Self.accountStamp(for: account) else { return }
    refreshInstallState()
    switch installState {
    case .unpaired, .appNotInstalled:
      // A prerequisite the person must satisfy outside Whirr; the view offers instructions and no
      // probe can succeed until it is met.
      connected = false
      return
    case .unknown, .ready:
      break
    }
    guard let hello = try? WatchSetupHello(id: UUID(), accountStamp: stamp, issuedAt: now()),
      let payload = try? WatchWireCodec.encode(hello)
    else { return }
    let token = setupAttemptEpoch
    isCheckingConnection = true
    let reply = await sender(payload, WatchTransportKey.setupStatus)
    isCheckingConnection = false
    guard token == setupAttemptEpoch, self.account == account, !connectInFlight else { return }
    guard let reply, let answer = try? WatchWireCodec.decode(WatchSetupChallenge.self, from: reply),
      answer.id == hello.id, answer.accountStamp == stamp
    else {
      lastProbe = .noAnswer
      return
    }
    switch answer.status {
    case .installed:
      connected = true
      lastProbe = .installed(answer.health)
      confirmWatchLink(health: answer.health, for: stamp.accountIdentityHash)
    case .ready, .wrongAccount:
      // Definitive: the Watch holds no account for this stamp, or holds someone else's.
      connected = false
      forgetWatchLink(for: stamp.accountIdentityHash)
      lastProbe = answer.status == .ready ? .notInstalled : .otherAccount
    case .busy, .rejected:
      // Says nothing about provisioning; leave the last confirmed answer standing.
      lastProbe = .noAnswer
    }
  }

  /// Whether this phone has persisted evidence that the Watch holds this account. The link record
  /// is the only thing written; the legacy key below is read for installs set up before it existed.
  private func remembersLink(for accountIdentityHash: String) -> Bool {
    record.load(accountIdentityHash: accountIdentityHash) != nil
      || defaults.string(forKey: Self.legacyConnectionKey) == accountIdentityHash
  }

  /// Holds one account identity hash and never a credential. Written until the link record existed;
  /// never written now, and cleared only by `forgetWatchLink`.
  private static let legacyConnectionKey = "watch.setup.connected.v1"

  /// Records the confirmation in memory and on disk together, so the screen's line and a later
  /// launch's record never disagree. The caller's clock supplies the time, so a live answer and a
  /// pushed report record identically.
  func confirmWatchLink(health: WatchLinkHealth?, for accountIdentityHash: String) {
    let confirmedAt = now()
    record.record(accountIdentityHash: accountIdentityHash, health: health, confirmedAt: confirmedAt)
    lastConfirmed = WatchLinkConfirmation(health: health, at: confirmedAt)
  }

  /// A status the Watch pushed in its application context. The phone cannot wake the Watch to ask,
  /// so this is the path that keeps an open screen's "Confirmed …" line fresh. It never clears the
  /// record: only a live definitive answer does that.
  func acceptStatusReport(_ report: WatchStatusReport) {
    guard let account, let stamp = try? Self.accountStamp(for: account) else { return }
    let hash = stamp.accountIdentityHash
    let outcome = WatchStatusReportAcceptance.outcome(
      for: report, accountIdentityHash: hash, stored: record.load(accountIdentityHash: hash), now: now())
    reportedAccount = outcome.reportedAccount
    guard case .accepted(let accepted) = outcome, let entry = accepted else { return }
    record.record(
      accountIdentityHash: hash, health: entry.health, confirmedAt: entry.confirmedAt,
      capabilities: entry.capabilities)
    lastConfirmed = WatchLinkConfirmation(health: entry.health, at: entry.confirmedAt)
  }

  /// What the Watch's last status report said it can do, read from the same record as
  /// `lastConfirmed`. The record has no capabilities until a report arrives, which reads as
  /// `.unknown`; a probe answer or a completed setup never supplies them. A transport state that
  /// says the app is gone overrides whatever the install last reported.
  var watchAppReadiness: WatchAppReadiness {
    guard let account, let stamp = try? Self.accountStamp(for: account) else {
      return WatchAppReadiness(installState: installState, capabilities: nil)
    }
    return WatchAppReadiness(
      installState: installState,
      capabilities: record.load(accountIdentityHash: stamp.accountIdentityHash)?.capabilities)
  }

  /// The Audiobookshelf dimension, read from the same record plus the report's account fact.
  var absReadiness: WatchABSReadiness {
    guard let account, let stamp = try? Self.accountStamp(for: account) else {
      return WatchABSReadiness(installState: installState, reportedAccount: .unknown, capabilities: nil)
    }
    return WatchABSReadiness(
      installState: installState, reportedAccount: reportedAccount,
      capabilities: record.load(accountIdentityHash: stamp.accountIdentityHash)?.capabilities)
  }

  private func forgetWatchLink(for accountIdentityHash: String) {
    if defaults.string(forKey: Self.legacyConnectionKey) == accountIdentityHash {
      defaults.removeObject(forKey: Self.legacyConnectionKey)
    }
    record.clear(accountIdentityHash: accountIdentityHash)
    lastConfirmed = nil
  }

  private func storedConfirmation(for accountIdentityHash: String) -> WatchLinkConfirmation? {
    record.load(accountIdentityHash: accountIdentityHash).map {
      WatchLinkConfirmation(health: $0.health, at: $0.confirmedAt)
    }
  }

  func bind(account: AccountRecord, reading: any ServerAccountReading) {
    setupAttemptEpoch &+= 1
    attempt = nil
    self.account = account
    self.reading = reading
    reportedAccount = .unknown
    releasePendingCredentials()
    // Nothing about the Watch's own provisioning is derivable from phone state, so seeding from
    // the last confirmed answer is what keeps a relaunch from presenting setup as never done.
    // `refreshConnectionStatus()` overrules this the moment the Watch is reachable.
    if let stamp = try? Self.accountStamp(for: account) {
      connected = remembersLink(for: stamp.accountIdentityHash)
      lastConfirmed = storedConfirmation(for: stamp.accountIdentityHash)
    } else {
      connected = false
      lastConfirmed = nil
    }
    lastProbe = .none
    wantsReconnect = false
    error = nil
    message = nil
    progress = 0
    state = .ready
    username = ""
    usernameIsVerified = false
    server = account.serverBaseURL
  }

  func unbind() {
    setupAttemptEpoch &+= 1
    attempt = nil
    releasePendingCredentials()
    account = nil
    reading = nil
    reportedAccount = .unknown
    connected = false
    lastConfirmed = nil
    lastProbe = .none
    wantsReconnect = false
    error = nil
    message = nil
    progress = 0
    state = .idle
    username = ""
    usernameIsVerified = false
    server = ""
  }

  func loadProfile() async {
    refreshInstallState()
    guard let reading, let account else { return }
    guard !connectInFlight, state != .waitingForReceipt, state != .connected else { return }
    let token = setupAttemptEpoch
    state = .loadingProfile
    error = nil
    message = nil
    do {
      let profile = try await reading.fetchProfile()
      guard token == setupAttemptEpoch, self.account == account, !connectInFlight, state == .loadingProfile else {
        return
      }
      if let profileUsername = profile.username,
        !profileUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        username = profileUsername
        usernameIsVerified = true
        message = nil
      } else {
        username = ""
        usernameIsVerified = false
        message = WatchSetupCopy.missingProfileUsername
      }
      state = .ready
    } catch {
      guard token == setupAttemptEpoch, self.account == account, !connectInFlight, state == .loadingProfile else {
        return
      }
      username = ""
      usernameIsVerified = false
      message = WatchSetupCopy.profileUnavailable
      state = .ready
    }
  }

  enum SetupFailure: Error {
    case invalidChallenge
    case accountMismatch

    @MainActor var message: String {
      switch self {
      case .invalidChallenge: return WatchSetupCopy.invalidChallenge
      case .accountMismatch: return WatchSetupCopy.accountMismatch
      }
    }
  }

  static func accountStamp(for account: AccountRecord) throws -> WatchAccountStamp {
    guard let url = URL(string: account.serverBaseURL) else { throw SetupFailure.accountMismatch }
    let server = try TokenAccount.normalizedServerIdentity(from: url)
    return try WatchAccountStamp.authenticated(serverIdentity: server, userID: account.serverUserId)
  }
}

import ABSApi
import AppModel
import Foundation
import Persistence
import SyncEngine
import TestSupport
import Testing
import WatchProtocol

@testable import Whirr

@MainActor
@Suite("Phone Watch setup")
struct WatchPhoneSetupModelTests {
  private let account = AccountRecord(
    clientUUID: "phone-client",
    serverBaseURL: "https://books.example.test",
    serverUserId: "user-1",
    serverVersion: "2.0.0")

  @Test func successfulSetupAcknowledgesInstalledReceipt() async throws {
    let counter = Counter()
    let model = makeModel(
      counter: counter,
      receiptStatus: .installed)
    model.bind(account: account, reading: WatchSetupReading())
    await model.loadProfile()
    await model.connect(password: "input")
    #expect(model.connected)
    #expect(model.state == .connected)
    #expect(counter.loginCount == 1)
    #expect(counter.credentialsSent == 1)
  }

  @Test func submitIsBusyFromTheTapUntilCompletionHasObservedTheOutcome() async throws {
    let model = makeModel(receiptStatus: .installed)
    model.bind(account: account, reading: WatchSetupReading())
    await model.loadProfile()
    var completionSawConnected: Bool?
    var busyDuringCompletion: Bool?
    model.submit(password: "input") { connected in
      completionSawConnected = connected
      busyDuringCompletion = model.isBusy
    }
    #expect(model.isBusy)
    await waitUntil { completionSawConnected != nil }
    #expect(completionSawConnected == true)
    #expect(busyDuringCompletion == true)
    await waitUntil { model.isBusy == false }
    #expect(model.connected)
  }

  @Test func wrongUserNeverTransfersCredentials() async throws {
    let counter = Counter()
    let reading = WatchSetupReading()
    let model = makeModel(
      counter: counter,
      loginUserID: "different-user")
    model.bind(account: account, reading: reading)
    await model.loadProfile()
    await model.connect(password: "input")
    #expect(model.connected == false)
    #expect(model.state == .failed)
    #expect(counter.loginCount == 1)
    #expect(counter.credentialsSent == 0)
  }

  @Test func lostReceiptRetriesIdenticalPayloadWithoutRelogin() async throws {
    let counter = Counter()
    var payloads: [Data] = []
    var first = true
    let model = WatchPhoneSetupModel(
      sender: { data, key in
        if key == WatchTransportKey.setupHello {
          let hello = try! WatchWireCodec.decode(WatchSetupHello.self, from: data)
          return try? WatchWireCodec.encode(
            WatchSetupChallenge(
              id: hello.id, accountStamp: hello.accountStamp, nonce: UUID(),
              expiresAt: Date().addingTimeInterval(90)))
        }
        payloads.append(data)
        if first {
          first = false
          return nil
        }
        let credentials = try! WatchWireCodec.decode(WatchSetupCredentials.self, from: data)
        return try? WatchWireCodec.encode(
          WatchSetupReceipt(
            id: credentials.id, accountStamp: credentials.accountStamp,
            nonce: credentials.nonce, status: .installed))
      },
      loginProvider: { url, method, _ in
        counter.loginCount += 1
        method.releasePassword()
        let server = try TokenAccount.normalizedServerIdentity(from: url)
        return .init(
          userID: "user-1", serverIdentity: server, defaultLibraryID: nil,
          accessToken: "access", refreshToken: "refresh", accessExpiry: nil,
          cleanup: { _ in })
      })
    model.bind(account: account, reading: WatchSetupReading())
    await model.loadProfile()
    await model.connect(password: "input")
    #expect(model.connected == false)
    await model.connect(password: "ignored")
    #expect(model.connected)
    #expect(counter.loginCount == 1)
    #expect(payloads.count == 2)
    #expect(payloads[0] == payloads[1])
  }

  @Test func busyReceiptPreservesPayloadForRetryWithoutCleanup() async throws {
    let counter = Counter()
    var payloads: [Data] = []
    var first = true
    let model = WatchPhoneSetupModel(
      sender: { data, key in
        if key == WatchTransportKey.setupHello {
          let hello = try! WatchWireCodec.decode(WatchSetupHello.self, from: data)
          return try? WatchWireCodec.encode(
            WatchSetupChallenge(
              id: hello.id, accountStamp: hello.accountStamp, nonce: UUID(),
              expiresAt: Date().addingTimeInterval(90)))
        }
        payloads.append(data)
        let credentials = try! WatchWireCodec.decode(WatchSetupCredentials.self, from: data)
        let status: WatchSetupStatus = first ? .busy : .installed
        first = false
        return try? WatchWireCodec.encode(
          WatchSetupReceipt(
            id: credentials.id, accountStamp: credentials.accountStamp,
            nonce: credentials.nonce, status: status))
      },
      loginProvider: { url, method, _ in
        counter.loginCount += 1
        method.releasePassword()
        let server = try TokenAccount.normalizedServerIdentity(from: url)
        return .init(
          userID: "user-1", serverIdentity: server, defaultLibraryID: nil,
          accessToken: "access", refreshToken: "refresh", accessExpiry: nil,
          cleanup: { _ in counter.cleanupCount += 1 })
      })
    model.bind(account: account, reading: WatchSetupReading())
    await model.loadProfile()
    await model.connect(password: "input")
    #expect(model.state == .waitingForReceipt)
    #expect(counter.cleanupCount == 0)
    await model.connect(password: "ignored")
    #expect(model.connected)
    #expect(counter.loginCount == 1)
    #expect(counter.cleanupCount == 1)
    #expect(payloads.count == 2)
    #expect(payloads[0] == payloads[1])
  }

  @Test func profileRefreshDoesNotOverwritePendingSetup() async throws {
    let model = makeModel(dropReceipt: true)
    model.bind(account: account, reading: WatchSetupReading())
    await model.loadProfile()
    // A pending delivery state is preserved when the view is revisited.
    await model.connect(password: "input")
    #expect(model.state == .waitingForReceipt)
    await model.loadProfile()
    #expect(model.username == "reader")
    #expect(model.state == .waitingForReceipt)
  }

  @Test func validPhoneProfilePrefillsAndLocksUsername() async throws {
    let model = makeModel()
    model.bind(account: account, reading: WatchSetupReading())

    await model.loadProfile()

    #expect(model.username == "reader")
    #expect(model.usernameIsVerified)
  }

  @Test func unavailablePhoneProfileOffersAccountRetry() async throws {
    let model = makeModel()
    model.bind(account: account, reading: WatchSetupUnavailableProfileReading())

    await model.loadProfile()

    #expect(model.username.isEmpty)
    #expect(!model.usernameIsVerified)
    #expect(model.message == "Couldn’t load your iPhone account. Check your connection and retry.")
  }

  @Test func missingPhoneProfileUsernameOffersAccountRetry() async throws {
    let model = makeModel()
    model.bind(account: account, reading: WatchSetupReading(profileUsername: nil))

    await model.loadProfile()

    #expect(model.username.isEmpty)
    #expect(!model.usernameIsVerified)
    #expect(model.message == "Your account username is unavailable. Retry loading your account.")
  }

  @Test func profileRetryRecoversWithoutManualAccountEntry() async throws {
    let counter = Counter()
    let model = makeModel(counter: counter)
    model.bind(account: account, reading: WatchSetupRecoveringProfileReading())
    await model.loadProfile()
    await model.connect(password: "input")
    #expect(!model.connected)
    #expect(counter.loginCount == 0)
    #expect(counter.credentialsSent == 0)

    await model.loadProfile()
    #expect(model.username == "reader")
    #expect(model.usernameIsVerified)
    #expect(model.message == nil)
    #expect(model.error == nil)
    await model.connect(password: "input")
    #expect(model.connected)
    #expect(counter.loginCount == 1)
  }

  @Test func rebindingClearsVerifiedUsername() async throws {
    let model = makeModel()
    model.bind(account: account, reading: WatchSetupReading())
    await model.loadProfile()
    #expect(model.usernameIsVerified)

    let replacement = AccountRecord(
      clientUUID: "phone-client-2", serverBaseURL: "https://other.example.test",
      serverUserId: "user-2", serverVersion: "2.0.0")
    model.bind(account: replacement, reading: WatchSetupReading())

    #expect(model.username.isEmpty)
    #expect(!model.usernameIsVerified)
  }

  @Test func staleProfileResponseCannotLockReboundAccount() async throws {
    let gate = WatchSetupProfileGate()
    let model = makeModel()
    model.bind(account: account, reading: WatchSetupDelayedProfileReading(gate: gate))
    let load = Task { await model.loadProfile() }
    await gate.waitUntilStarted()

    let replacement = AccountRecord(
      clientUUID: "phone-client-2", serverBaseURL: "https://other.example.test",
      serverUserId: "user-2", serverVersion: "2.0.0")
    model.bind(account: replacement, reading: WatchSetupReading())
    await gate.open()
    await load.value

    #expect(model.username.isEmpty)
    #expect(!model.usernameIsVerified)
  }

  @Test func accountChangePreventsCredentialTransfer() async throws {
    let gate = AsyncGate()
    let counter = Counter()
    let model = WatchPhoneSetupModel(
      sender: { data, key in
        if key == WatchTransportKey.setupHello {
          let hello = try! WatchWireCodec.decode(WatchSetupHello.self, from: data)
          return try? WatchWireCodec.encode(
            WatchSetupChallenge(
              id: hello.id, accountStamp: hello.accountStamp, nonce: UUID(),
              expiresAt: Date().addingTimeInterval(90)))
        }
        counter.credentialsSent += 1
        return nil
      },
      loginProvider: { url, method, _ in
        method.releasePassword()
        await gate.wait()
        let server = try TokenAccount.normalizedServerIdentity(from: url)
        return .init(
          userID: "user-1", serverIdentity: server, defaultLibraryID: nil,
          accessToken: "access", refreshToken: "refresh", accessExpiry: nil,
          cleanup: { _ in })
      })
    model.bind(account: account, reading: WatchSetupReading())
    await model.loadProfile()
    let operation = Task { await model.connect(password: "input") }
    await Task.yield()
    model.unbind()
    await gate.open()
    await operation.value
    #expect(counter.credentialsSent == 0)
  }

  @Test func failedReceiptDoesNotReportSuccess() async throws {
    let model = makeModel(receiptStatus: .rejected)
    model.bind(account: account, reading: WatchSetupReading())
    await model.loadProfile()
    await model.connect(password: "input")
    #expect(model.connected == false)
    #expect(model.state == .failed)
  }

  @Test func unpairedWatchExplainsPairingInsteadOfAttemptingDelivery() async throws {
    let counter = Counter()
    let model = makeModel(counter: counter, installState: .unpaired)
    model.bind(account: account, reading: WatchSetupReading())
    await model.loadProfile()

    #expect(model.installState == .unpaired)
    #expect(model.isBlockedOnInstall)

    await model.connect(password: "input")

    #expect(!model.connected)
    #expect(model.state == .failed)
    #expect(model.error == "No Apple Watch is paired with this iPhone. Pair one, then come back to finish setup.")
    #expect(counter.loginCount == 0)
    #expect(counter.credentialsSent == 0)
  }

  @Test func missingWatchAppNamesTheInstallStepRatherThanProximity() async throws {
    let counter = Counter()
    let model = makeModel(counter: counter, installState: .appNotInstalled)
    model.bind(account: account, reading: WatchSetupReading())
    await model.loadProfile()

    #expect(model.isBlockedOnInstall)
    #expect(model.installGuidance?.contains("Available Apps") == true)

    await model.connect(password: "input")

    #expect(!model.connected)
    #expect(model.state == .failed)
    #expect(model.error?.contains("Install Whirr on your Apple Watch first.") == true)
    // The old copy sent people to move the Watch closer, which never resolves a missing install.
    #expect(model.error?.contains("Keep the Watch nearby") == false)
    #expect(counter.loginCount == 0)
    #expect(counter.credentialsSent == 0)
  }

  @Test func readyWatchIsNotBlockedAndCompletesSetup() async throws {
    let counter = Counter()
    let model = makeModel(counter: counter, installState: .ready)
    model.bind(account: account, reading: WatchSetupReading())
    await model.loadProfile()

    #expect(!model.isBlockedOnInstall)
    #expect(model.installGuidance == nil)

    await model.connect(password: "input")

    #expect(model.connected)
    #expect(counter.credentialsSent == 1)
  }

  @Test func unknownInstallStateNeverBlocksAnAttempt() async throws {
    // Before WatchConnectivity activates, nothing can be asserted; setup must still be attemptable.
    let counter = Counter()
    let model = makeModel(counter: counter, installState: .unknown)
    model.bind(account: account, reading: WatchSetupReading())
    await model.loadProfile()

    #expect(!model.isBlockedOnInstall)
    #expect(model.installGuidance == nil)

    await model.connect(password: "input")

    #expect(model.connected)
    #expect(counter.credentialsSent == 1)
  }

  @Test func installArrivingWhileTheScreenIsOpenClearsTheGuidance() async throws {
    let reported = Reported(state: .appNotInstalled)
    let model = makeModel(installState: nil, installStateReader: { reported.state })
    model.bind(account: account, reading: WatchSetupReading())
    await model.loadProfile()
    #expect(model.isBlockedOnInstall)

    reported.state = .ready
    model.refreshInstallState()

    #expect(!model.isBlockedOnInstall)
    #expect(model.installGuidance == nil)

    await model.connect(password: "input")
    #expect(model.connected)
  }

  /// Settings offers Apple Watch only once WatchConnectivity reports a paired Watch. An iPad never
  /// activates a session, so it stays `.unknown` and never shows the row.
  @Test func settingsOffersAppleWatchOnlyWithAPairedWatch() {
    let reported = Reported(state: .unknown)
    let model = makeModel(installState: nil, installStateReader: { reported.state })
    let expected: [(WatchInstallState, Bool)] = [
      (.unknown, false), (.unpaired, false), (.appNotInstalled, true), (.ready, true),
    ]
    for (state, offered) in expected {
      reported.state = state
      model.refreshInstallState()
      #expect(model.offersSettingsEntry == offered, "\(state)")
    }
  }

  /// A volatile domain per model: the connection memory is real `UserDefaults` state, and tests
  /// must neither read the developer's nor leak an answer into one another.
  static func scratchDefaults() -> UserDefaults {
    UserDefaults(suiteName: "watch.setup.tests.\(UUID().uuidString)")!
  }

  @Test func anAlreadyProvisionedWatchIsReportedWithoutAskingForAPassword() async throws {
    let counter = Counter()
    let model = makeModel(counter: counter, installState: .ready, statusAnswer: { .installed })
    model.bind(account: account, reading: WatchSetupReading())
    #expect(!model.connected)

    await model.refreshConnectionStatus()

    #expect(model.connected)
    #expect(!model.isCheckingConnection)
    #expect(counter.statusProbes == 1)
    // The whole point: no login, and no credential transfer that would log the Watch out remotely.
    #expect(counter.loginCount == 0)
    #expect(counter.credentialsSent == 0)
  }

  @Test func aConfirmedConnectionSurvivesRelaunchSoUpdatesDoNotReadAsDisconnected() async throws {
    let defaults = Self.scratchDefaults()
    let first = makeModel(installState: .ready, defaults: defaults)
    first.bind(account: account, reading: WatchSetupReading())
    await first.loadProfile()
    await first.connect(password: "input")
    #expect(first.connected)

    // A relaunch: a fresh model over the same stored state, before the Watch is reachable.
    let second = makeModel(installState: .ready, defaults: defaults)
    second.bind(account: account, reading: WatchSetupReading())
    #expect(second.connected)
  }

  @Test func aWatchThatLostItsAccountClearsTheRememberedAnswer() async throws {
    let defaults = Self.scratchDefaults()
    let first = makeModel(installState: .ready, defaults: defaults)
    first.bind(account: account, reading: WatchSetupReading())
    await first.loadProfile()
    await first.connect(password: "input")
    #expect(first.connected)

    let second = makeModel(installState: .ready, defaults: defaults, statusAnswer: { .ready })
    second.bind(account: account, reading: WatchSetupReading())
    #expect(second.connected)
    await second.refreshConnectionStatus()
    #expect(!second.connected)

    let third = makeModel(installState: .ready, defaults: defaults)
    third.bind(account: account, reading: WatchSetupReading())
    #expect(!third.connected)
  }

  @Test func anUnreachableWatchLeavesTheLastConfirmedAnswerStanding() async throws {
    let defaults = Self.scratchDefaults()
    let first = makeModel(installState: .ready, defaults: defaults)
    first.bind(account: account, reading: WatchSetupReading())
    await first.loadProfile()
    await first.connect(password: "input")

    // No reply: the Watch is asleep or out of range, which says nothing about its provisioning.
    let second = makeModel(counter: nil, installState: .ready, defaults: defaults, statusAnswer: { nil })
    second.bind(account: account, reading: WatchSetupReading())
    await second.refreshConnectionStatus()
    #expect(second.connected)
    #expect(!second.isCheckingConnection)
  }

  @Test func anAmbiguousAnswerNeverOverturnsAConfirmedConnection() async throws {
    let defaults = Self.scratchDefaults()
    let first = makeModel(installState: .ready, defaults: defaults)
    first.bind(account: account, reading: WatchSetupReading())
    await first.loadProfile()
    await first.connect(password: "input")

    for status in [WatchSetupStatus.busy, .rejected] {
      let model = makeModel(installState: .ready, defaults: defaults, statusAnswer: { status })
      model.bind(account: account, reading: WatchSetupReading())
      await model.refreshConnectionStatus()
      #expect(model.connected)
    }

    // A Watch that reports another account is not ambiguous: it is a definitive "not you".
    let foreign = makeModel(installState: .ready, defaults: defaults, statusAnswer: { .wrongAccount })
    foreign.bind(account: account, reading: WatchSetupReading())
    await foreign.refreshConnectionStatus()
    #expect(!foreign.connected)
  }

  @Test func aMissingWatchAppIsReportedAsNotConnectedWithoutProbing() async throws {
    let defaults = Self.scratchDefaults()
    let first = makeModel(installState: .ready, defaults: defaults)
    first.bind(account: account, reading: WatchSetupReading())
    await first.loadProfile()
    await first.connect(password: "input")

    let counter = Counter()
    let model = makeModel(
      counter: counter, installState: .appNotInstalled, defaults: defaults, statusAnswer: { .installed })
    model.bind(account: account, reading: WatchSetupReading())
    await model.refreshConnectionStatus()

    #expect(!model.connected)
    #expect(counter.statusProbes == 0)
  }

  @Test func aProbeNeverDisturbsAnAttemptThatIsWaitingForItsReceipt() async throws {
    let counter = Counter()
    let model = makeModel(counter: counter, dropReceipt: true, installState: .ready, statusAnswer: { .installed })
    model.bind(account: account, reading: WatchSetupReading())
    await model.loadProfile()
    await model.connect(password: "input")
    #expect(model.state == .waitingForReceipt)

    await model.refreshConnectionStatus()

    #expect(model.state == .waitingForReceipt)
    #expect(!model.connected)
    #expect(counter.statusProbes == 0)
  }

  @Test func aWatchWhoseSignInWasRejectedAsksForReconnectionNotACheck() async throws {
    let model = makeModel(installState: .ready, statusAnswer: { .installed }, health: { .signInRejected })
    model.bind(account: account, reading: WatchSetupReading())
    await model.refreshConnectionStatus()

    #expect(model.connected)
    #expect(model.linkStatus == .signInRejected)
    #expect(model.linkStatus.primaryAction == .reconnect)
  }

  @Test func aWorkingWatchLeadsWithItsStatusNotTheSetupForm() async throws {
    let model = makeModel(installState: .ready, statusAnswer: { .installed }, health: { .healthy })
    model.bind(account: account, reading: WatchSetupReading())
    await model.loadProfile()
    await model.refreshConnectionStatus()

    #expect(model.linkStatus == .working)
    #expect(!model.linkStatus.showsSetupForm)
    model.beginReconnect()
    #expect(model.linkStatus == .settingUp)
    model.cancelReconnect()
    #expect(model.linkStatus == .working)
  }

  @Test func anUnansweredProbeWithNothingRememberedIsNotTreatedAsUnprovisioned() async throws {
    let model = makeModel(installState: .ready, statusAnswer: { nil })
    model.bind(account: account, reading: WatchSetupReading())
    await model.refreshConnectionStatus()

    #expect(model.lastProbe == .noAnswer)
    #expect(model.linkStatus == .unreachable)
    #expect(!model.linkStatus.showsSetupForm)
  }

  @Test func onlyAWatchWithNoAccountIsOfferedSetup() async throws {
    let model = makeModel(installState: .ready, statusAnswer: { .ready })
    model.bind(account: account, reading: WatchSetupReading())
    await model.refreshConnectionStatus()
    #expect(model.linkStatus == .notSetUp)

    let foreign = makeModel(installState: .ready, statusAnswer: { .wrongAccount })
    foreign.bind(account: account, reading: WatchSetupReading())
    await foreign.refreshConnectionStatus()
    #expect(foreign.linkStatus == .otherAccount)
    foreign.beginReconnect()
    #expect(foreign.linkStatus == .otherAccount)
  }

  @Test func aReconnectForgetsTheOldVerdictAndCanBeCheckedAgain() async throws {
    let counter = Counter()
    let health = ReportedHealth(.signInRejected)
    let model = makeModel(
      counter: counter, installState: .ready, statusAnswer: { .installed }, health: { health.value })
    model.bind(account: account, reading: WatchSetupReading())
    await model.loadProfile()
    await model.refreshConnectionStatus()
    #expect(model.linkStatus == .signInRejected)

    model.beginReconnect()
    await model.connect(password: "input")
    #expect(model.state == .connected)
    #expect(model.lastProbe == .installed(nil))
    #expect(!model.wantsReconnect)
    #expect(model.linkStatus == .working)

    health.value = .healthy
    await model.refreshConnectionStatus()
    #expect(counter.statusProbes == 2)
    #expect(model.lastProbe == .installed(.healthy))
  }

  @Test func rebindingForgetsTheProbeAndTheReconnectIntent() async throws {
    let model = makeModel(installState: .ready, statusAnswer: { .installed }, health: { .healthy })
    model.bind(account: account, reading: WatchSetupReading())
    await model.refreshConnectionStatus()
    model.beginReconnect()

    model.bind(account: account, reading: WatchSetupReading())
    #expect(model.lastProbe == .none)
    #expect(!model.wantsReconnect)
  }

  @Test func aProbeAnswerIsRecordedForARelaunchToDate() async throws {
    let defaults = Self.scratchDefaults()
    let at = Date(timeIntervalSinceReferenceDate: 7_000)
    let first = makeModel(
      installState: .ready, defaults: defaults, now: { at }, statusAnswer: { .installed },
      health: { .serverUnreachable })
    first.bind(account: account, reading: WatchSetupReading())
    await first.refreshConnectionStatus()
    #expect(first.confirmedAt == at)

    let second = makeModel(
      installState: .ready, defaults: defaults, statusAnswer: { nil })
    second.bind(account: account, reading: WatchSetupReading())
    #expect(second.linkStatus == .serverUnreachable)
    #expect(second.confirmedAt == at)

    await second.refreshConnectionStatus()
    #expect(second.linkStatus == .serverUnreachable)
    #expect(second.confirmedAt == at)
  }

  @Test func aLiveProbeAnswerWritesOnlyTheRecord() async throws {
    let defaults = Self.scratchDefaults()
    let at = Date(timeIntervalSinceReferenceDate: 8_000)
    let model = makeModel(
      installState: .ready, defaults: defaults, now: { at }, statusAnswer: { .installed },
      health: { .healthy })
    model.bind(account: account, reading: WatchSetupReading())
    await model.refreshConnectionStatus()

    // The record is the one persisted answer; the legacy key is read-only for older installs.
    #expect(defaults.string(forKey: "watch.setup.connected.v1") == nil)
    let entry = WatchLinkRecord(defaults: defaults).load(
      accountIdentityHash: try stamp().accountIdentityHash)
    #expect(entry?.health == .healthy)
    #expect(entry?.confirmedAt == at)
  }

  @Test func aCompletedSetupIsRecordedAsConfirmed() async throws {
    let defaults = Self.scratchDefaults()
    // A fixed clock near the real one: the fake Watch dates its challenge from `Date()`, and the
    // model accepts a challenge only when it expires within the setup window of `now`.
    let at = Date()
    let first = makeModel(installState: .ready, defaults: defaults, now: { at })
    first.bind(account: account, reading: WatchSetupReading())
    await first.loadProfile()
    await first.connect(password: "input")
    #expect(first.confirmedAt == at)

    let second = makeModel(installState: .ready, defaults: defaults, statusAnswer: { nil })
    second.bind(account: account, reading: WatchSetupReading())
    #expect(second.linkStatus == .working)
    #expect(second.confirmedAt == at)
  }

  @Test func aDefinitiveNotInstalledAnswerClearsTheRecord() async throws {
    let defaults = Self.scratchDefaults()
    let at = Date(timeIntervalSinceReferenceDate: 9_000)
    let first = makeModel(
      counter: nil, installState: .ready, defaults: defaults, now: { at }, statusAnswer: { .installed },
      health: { .healthy })
    first.bind(account: account, reading: WatchSetupReading())
    await first.refreshConnectionStatus()
    #expect(first.confirmedAt == at)

    let second = makeModel(installState: .ready, defaults: defaults, statusAnswer: { .ready })
    second.bind(account: account, reading: WatchSetupReading())
    #expect(second.linkStatus == .working)
    await second.refreshConnectionStatus()
    #expect(second.linkStatus == .notSetUp)
    #expect(second.confirmedAt == nil)

    let third = makeModel(installState: .ready, defaults: defaults, statusAnswer: { nil })
    third.bind(account: account, reading: WatchSetupReading())
    #expect(third.linkStatus == .unreachable)
    #expect(third.confirmedAt == nil)
  }

  @Test func aRememberedConnectionWithoutARecordIsSetUpNotConnected() throws {
    let defaults = Self.scratchDefaults()
    // The state an install set up before the record existed has: the legacy key and no record.
    defaults.set(try stamp().accountIdentityHash, forKey: "watch.setup.connected.v1")

    let model = makeModel(installState: .ready, defaults: defaults)
    model.bind(account: account, reading: WatchSetupReading())
    #expect(model.connected)
    #expect(model.linkStatus == .unconfirmed)
    #expect(model.confirmedAt == nil)
  }

  @Test func reachabilityIsPublishedForTheVisibleScreen() {
    let model = makeModel()
    #expect(!model.isWatchReachable)
    model.watchReachabilityChanged(isReachable: true)
    #expect(model.isWatchReachable)
    model.watchReachabilityChanged(isReachable: false)
    #expect(!model.isWatchReachable)
  }

  @Test func aPushedStatusReportDatesTheConfirmation() throws {
    let at = Date()
    let checkedAt = at.addingTimeInterval(-120)
    let model = makeModel(installState: .ready, now: { at })
    model.bind(account: account, reading: WatchSetupReading())

    model.acceptStatusReport(
      try WatchStatusReport(
        accountStamp: try stamp(), health: .healthy, checkedAt: checkedAt, reportedAt: at))

    #expect(model.confirmedAt == checkedAt)
    #expect(model.lastConfirmed?.health == .healthy)
    #expect(model.linkStatus == .working)
  }

  @Test func theWatchAppReadinessFollowsTheLatestReport() throws {
    let at = Date()
    let model = makeModel(installState: .ready, now: { at })
    model.bind(account: account, reading: WatchSetupReading())
    #expect(model.watchAppReadiness == .unknown)

    model.acceptStatusReport(
      try WatchStatusReport(
        accountStamp: try stamp(), health: .healthy, checkedAt: at.addingTimeInterval(-10),
        reportedAt: at, capabilities: [WatchStatusCapability.enclosureFetch]))
    #expect(model.watchAppReadiness == .canFetch)

    model.acceptStatusReport(
      try WatchStatusReport(
        accountStamp: try stamp(), health: .healthy, checkedAt: at.addingTimeInterval(-5),
        reportedAt: at, capabilities: []))
    #expect(model.watchAppReadiness == .needsUpdate)
  }

  @Test func aMissingWatchAppOverridesTheReportedReadiness() throws {
    let at = Date()
    let reported = Reported(state: .ready)
    let model = makeModel(installState: nil, installStateReader: { reported.state }, now: { at })
    model.bind(account: account, reading: WatchSetupReading())
    model.acceptStatusReport(
      try WatchStatusReport(
        accountStamp: try stamp(), health: .healthy, checkedAt: at.addingTimeInterval(-10),
        reportedAt: at, capabilities: [WatchStatusCapability.enclosureFetch]))
    #expect(model.watchAppReadiness == .canFetch)

    // A deleted Watch app takes its copies with it, whatever the last report said it could do.
    reported.state = .appNotInstalled
    model.refreshInstallState()
    #expect(model.watchAppReadiness == .notInstalled)

    reported.state = .unpaired
    model.refreshInstallState()
    #expect(model.watchAppReadiness == .notInstalled)

    // A reinstall reads as the record's capabilities again; the new install's inventory decides
    // what the copies say.
    reported.state = .ready
    model.refreshInstallState()
    #expect(model.watchAppReadiness == .canFetch)
  }

  @Test func aLaterProbeKeepsTheReportedCapabilities() async throws {
    let at = Date()
    let model = makeModel(
      installState: .ready, now: { at }, statusAnswer: { .installed })
    model.bind(account: account, reading: WatchSetupReading())
    model.acceptStatusReport(
      try WatchStatusReport(
        accountStamp: try stamp(), health: .healthy, checkedAt: at.addingTimeInterval(-60),
        reportedAt: at, capabilities: [WatchStatusCapability.enclosureFetch]))

    await model.refreshConnectionStatus()

    #expect(model.lastProbe == .installed(nil))
    #expect(model.watchAppReadiness == .canFetch)
  }

  @Test func aPushedStatusReportIsDatedFromItsCheckTimeNotTheReportTime() throws {
    let at = Date()
    let checkedAt = at.addingTimeInterval(-600)
    let model = makeModel(installState: .ready, now: { at })
    model.bind(account: account, reading: WatchSetupReading())

    model.acceptStatusReport(
      try WatchStatusReport(
        accountStamp: try stamp(), health: .serverUnreachable, checkedAt: checkedAt, reportedAt: at))

    #expect(model.confirmedAt == checkedAt)
    #expect(model.linkStatus == .serverUnreachable)
  }

  @Test func aPushedStatusReportCannotRollBackOrClearTheConfirmation() throws {
    let at = Date()
    let checkedAt = at.addingTimeInterval(-60)
    let model = makeModel(installState: .ready, now: { at })
    model.bind(account: account, reading: WatchSetupReading())
    model.acceptStatusReport(
      try WatchStatusReport(accountStamp: try stamp(), health: .healthy, checkedAt: checkedAt, reportedAt: at))

    model.acceptStatusReport(
      try WatchStatusReport(
        accountStamp: try stamp(), health: .signInRejected, checkedAt: checkedAt.addingTimeInterval(-1),
        reportedAt: at))
    model.acceptStatusReport(
      try WatchStatusReport(accountStamp: nil, health: nil, checkedAt: nil, reportedAt: at))
    model.acceptStatusReport(
      try WatchStatusReport(accountStamp: try stamp(), health: .healthy, checkedAt: nil, reportedAt: at))

    #expect(model.confirmedAt == checkedAt)
    #expect(model.lastConfirmed?.health == .healthy)
  }

  @Test func aStatusReportForAnotherAccountIsIgnored() throws {
    let at = Date()
    let server = try TokenAccount.normalizedServerIdentity(from: URL(string: account.serverBaseURL)!)
    let otherAccount = try WatchAccountStamp.authenticated(serverIdentity: server, userID: "user-2")
    let model = makeModel(installState: .ready, now: { at })
    model.bind(account: account, reading: WatchSetupReading())

    model.acceptStatusReport(
      try WatchStatusReport(
        accountStamp: otherAccount, health: .healthy, checkedAt: at.addingTimeInterval(-10),
        reportedAt: at))

    #expect(model.confirmedAt == nil)
    #expect(model.lastConfirmed == nil)
  }

  @Test func aStatusReportDatedMoreThanFiveMinutesAheadIsIgnored() throws {
    let at = Date()
    let model = makeModel(installState: .ready, now: { at })
    model.bind(account: account, reading: WatchSetupReading())

    model.acceptStatusReport(
      try WatchStatusReport(
        accountStamp: try stamp(), health: .healthy,
        checkedAt: at.addingTimeInterval(WatchStatusReportAcceptance.futureTolerance + 1), reportedAt: at))

    #expect(model.confirmedAt == nil)
  }

  @Test func aPushedStatusReportSurvivesRelaunchForTheScreenToDate() throws {
    let defaults = Self.scratchDefaults()
    let at = Date()
    let checkedAt = at.addingTimeInterval(-900)
    let first = makeModel(installState: .ready, defaults: defaults, now: { at })
    first.bind(account: account, reading: WatchSetupReading())
    first.acceptStatusReport(
      try WatchStatusReport(accountStamp: try stamp(), health: .healthy, checkedAt: checkedAt, reportedAt: at))

    let second = makeModel(installState: .ready, defaults: defaults, now: { at })
    second.bind(account: account, reading: WatchSetupReading())

    #expect(second.linkStatus == .working)
    #expect(second.confirmedAt == checkedAt)
  }

  /// A status report writes only the record. A probe in flight must therefore read the record
  /// instead of falling back to "Checking", which would hide a status the Watch just pushed.
  @Test func anAcceptedStatusReportAnswersAProbeInFlightAfterRelaunch() async throws {
    let defaults = Self.scratchDefaults()
    let at = Date()
    let first = makeModel(installState: .ready, defaults: defaults, now: { at })
    first.bind(account: account, reading: WatchSetupReading())
    first.acceptStatusReport(
      try WatchStatusReport(
        accountStamp: try stamp(), health: .healthy, checkedAt: at.addingTimeInterval(-60),
        reportedAt: at))

    let probe = AsyncGate()
    let second = WatchPhoneSetupModel(
      sender: { _, key in
        guard key == WatchTransportKey.setupStatus else { return nil }
        await probe.wait()
        return nil
      },
      now: { at },
      installState: { .ready },
      defaults: defaults)
    second.bind(account: account, reading: WatchSetupReading())
    #expect(second.linkStatus == .working)

    let refresh = Task { await second.refreshConnectionStatus() }
    let started = await waitUntil("probe in flight") { second.isCheckingConnection }
    #expect(started)
    #expect(second.linkStatus == .working)
    await probe.open()
    await refresh.value
    #expect(second.lastProbe == .noAnswer)
    #expect(second.linkStatus == .working)
  }

  @Test func aRecordForAnotherAccountIsNotRemembered() async throws {
    let defaults = Self.scratchDefaults()
    let at = Date(timeIntervalSinceReferenceDate: 10_000)
    WatchLinkRecord(defaults: defaults).record(
      accountIdentityHash: try stamp(userID: "user-2").accountIdentityHash, health: .healthy,
      confirmedAt: at)

    let model = makeModel(installState: .ready, defaults: defaults, statusAnswer: { nil })
    model.bind(account: account, reading: WatchSetupReading())
    #expect(!model.connected)

    await model.refreshConnectionStatus()
    #expect(model.lastProbe == .noAnswer)
    #expect(model.linkStatus == .unreachable)
  }

  private func stamp(userID: String = "user-1") throws -> WatchAccountStamp {
    let server = try TokenAccount.normalizedServerIdentity(from: URL(string: account.serverBaseURL)!)
    return try WatchAccountStamp.authenticated(serverIdentity: server, userID: userID)
  }

  private func makeModel(
    counter: Counter? = nil,
    receiptStatus: WatchSetupStatus = .installed,
    loginUserID: String = "user-1",
    dropReceipt: Bool = false,
    installState: WatchInstallState? = .unknown,
    installStateReader: (@MainActor () -> WatchInstallState)? = nil,
    defaults: UserDefaults? = nil,
    now: (@MainActor () -> Date)? = nil,
    statusAnswer: (@MainActor () -> WatchSetupStatus?)? = nil,
    health: (@MainActor () -> WatchLinkHealth?)? = nil
  ) -> WatchPhoneSetupModel {
    let counter = counter ?? Counter()
    return WatchPhoneSetupModel(
      sender: { data, key in
        if key == WatchTransportKey.setupStatus {
          counter.statusProbes += 1
          guard let statusAnswer, let status = statusAnswer() else { return nil }
          let hello = try! WatchWireCodec.decode(WatchSetupHello.self, from: data)
          return try? WatchWireCodec.encode(
            WatchSetupChallenge(
              id: hello.id, accountStamp: hello.accountStamp, nonce: UUID(), expiresAt: Date(), status: status,
              health: health?()))
        }
        if key == WatchTransportKey.setupHello {
          let hello = try! WatchWireCodec.decode(WatchSetupHello.self, from: data)
          return try? WatchWireCodec.encode(
            WatchSetupChallenge(
              id: hello.id, accountStamp: hello.accountStamp, nonce: UUID(),
              expiresAt: Date().addingTimeInterval(90)))
        }
        counter.credentialsSent += 1
        let credentials = try! WatchWireCodec.decode(WatchSetupCredentials.self, from: data)
        if dropReceipt { return nil }
        return try? WatchWireCodec.encode(
          WatchSetupReceipt(
            id: credentials.id, accountStamp: credentials.accountStamp,
            nonce: credentials.nonce, status: receiptStatus))
      },
      now: now ?? { Date() },
      loginProvider: { url, method, _ in
        counter.loginCount += 1
        method.releasePassword()
        let server = try TokenAccount.normalizedServerIdentity(from: url)
        return .init(
          userID: loginUserID, serverIdentity: server, defaultLibraryID: nil,
          accessToken: "access", refreshToken: "refresh", accessExpiry: nil,
          cleanup: { _ in })
      },
      installState: installStateReader ?? { installState ?? .unknown },
      defaults: defaults ?? Self.scratchDefaults())
  }
}

/// A transport prerequisite that can change between reads, standing in for a Watch install that
/// completes while the setup screen is open.
@MainActor
private final class Reported {
  var state: WatchInstallState

  init(state: WatchInstallState) {
    self.state = state
  }
}

@MainActor
private final class ReportedHealth {
  var value: WatchLinkHealth?
  init(_ value: WatchLinkHealth?) { self.value = value }
}

@MainActor
private final class Counter {
  var loginCount = 0
  var credentialsSent = 0
  var cleanupCount = 0
  var statusProbes = 0
}

private actor AsyncGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func open() {
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending { waiter.resume() }
  }
}

@MainActor
@Suite("Phone Watch setup retry fencing")
struct WatchPhoneSetupRetryTests {
  private let account = AccountRecord(
    clientUUID: "retry-client",
    serverBaseURL: "https://books.example.test",
    serverUserId: "user-1",
    serverVersion: "2.0.0")
  private let now = Date(timeIntervalSinceReferenceDate: 100)

  @Test func lostHelloReplyRetriesSameHelloAndLogsInOnce() async throws {
    let fixture = RetryFixture(now: now)
    fixture.dropFirstHelloReply = true
    let model = fixture.model(account: account)
    model.bind(account: account, reading: WatchSetupRetryReading())
    await model.loadProfile()

    await model.connect(password: "input")
    #expect(model.connected == false)
    await model.connect(password: "ignored")

    #expect(model.connected)
    #expect(fixture.loginCount == 1)
    #expect(fixture.helloIDs.count == 2)
    #expect(fixture.helloIDs[0] == fixture.helloIDs[1])
    #expect(fixture.helloStamps[0] == fixture.helloStamps[1])
  }

  @Test func failedLoginRetriesSameHelloWithoutChangingRequestIdentity() async throws {
    let fixture = RetryFixture(now: now)
    fixture.failFirstLogin = true
    let model = fixture.model(account: account)
    model.bind(account: account, reading: WatchSetupRetryReading())
    await model.loadProfile()

    await model.connect(password: "input")
    #expect(model.connected == false)
    await model.connect(password: "input-again")

    #expect(model.connected)
    #expect(fixture.loginCount == 2)
    #expect(fixture.helloIDs.count == 2)
    #expect(fixture.helloIDs[0] == fixture.helloIDs[1])
    #expect(fixture.helloStamps[0] == fixture.helloStamps[1])
    #expect(fixture.credentialsCount == 1)
  }

  /// API-CONVENTIONS rule 5a: the Watch's password login backs off after a failure like setup's.
  @Test func failedLoginPacesTheNextPasswordAttempt() async throws {
    let fixture = RetryFixture(now: now)
    fixture.failFirstLogin = true
    // A fixed clock: on the real one, the 1 s first-failure delay can elapse between the two
    // attempts on a loaded machine and admit the second login.
    let clock = now
    fixture.loginBackoffGate = LoginBackoffGate(now: { clock }, randomUnit: { 1 })
    let model = fixture.model(account: account)
    model.bind(account: account, reading: WatchSetupRetryReading())
    await model.loadProfile()

    await model.connect(password: "input")
    await model.connect(password: "input-again")

    #expect(model.connected == false)
    #expect(fixture.loginCount == 1)
    #expect(fixture.credentialsCount == 0)
  }

  @Test func rejectedInstallRetriesThePendingChallengeWithFreshLogin() async throws {
    let fixture = RetryFixture(now: now)
    fixture.rejectFirstInstall = true
    let model = fixture.model(account: account)
    model.bind(account: account, reading: WatchSetupRetryReading())
    await model.loadProfile()
    await model.connect(password: "input")
    #expect(!model.connected)
    await model.connect(password: "input")
    #expect(model.connected)
    #expect(fixture.loginCount == 2)
    #expect(fixture.credentialsCount == 2)
    #expect(fixture.helloIDs.count == 2)
    #expect(fixture.helloIDs.first == fixture.helloIDs.last)
  }

}

@MainActor
private final class RetryFixture {
  let now: Date
  var admission = WatchSetupAdmission()
  var dropFirstHelloReply = false
  var failFirstLogin = false
  var rejectFirstInstall = false
  /// Zero jitter: a failure arms a window that is already closed, so retries are admitted.
  var loginBackoffGate = LoginBackoffGate(randomUnit: { 0 })
  var loginCount = 0
  var credentialsCount = 0
  var helloIDs: [UUID] = []
  var helloStamps: [WatchAccountStamp] = []
  private var helloReplyWasDropped = false

  init(now: Date) {
    self.now = now
  }

  func model(account: AccountRecord) -> WatchPhoneSetupModel {
    WatchPhoneSetupModel(
      sender: { [weak self] data, key in
        guard let self else { return nil }
        if key == WatchTransportKey.setupHello {
          guard let hello = try? WatchWireCodec.decode(WatchSetupHello.self, from: data) else { return nil }
          self.helloIDs.append(hello.id)
          self.helloStamps.append(hello.accountStamp)
          let challenge = self.admission.begin(hello, existingAccount: nil, now: self.now)
          if self.dropFirstHelloReply && !self.helloReplyWasDropped {
            self.helloReplyWasDropped = true
            return nil
          }
          return try? WatchWireCodec.encode(challenge)
        }

        guard key == WatchTransportKey.setupCredentials,
          let credentials = try? WatchWireCodec.decode(WatchSetupCredentials.self, from: data)
        else { return nil }
        self.credentialsCount += 1
        do {
          if try self.admission.admit(credentials, now: self.now) {
            guard let receipt = self.admission.receipt else { return nil }
            return try WatchWireCodec.encode(receipt)
          }
          if self.rejectFirstInstall && self.credentialsCount == 1 {
            return try WatchWireCodec.encode(
              WatchSetupReceipt(
                id: credentials.id, accountStamp: credentials.accountStamp, nonce: credentials.nonce, status: .rejected)
            )
          }
          let receipt = try self.admission.complete(credentials, now: self.now)
          return try WatchWireCodec.encode(receipt)
        } catch {
          return nil
        }
      },
      now: { self.now },
      loginProvider: { [weak self] url, method, _ in
        guard let self else { throw RetrySetupFailure.deallocated }
        self.loginCount += 1
        method.releasePassword()
        if self.failFirstLogin && self.loginCount == 1 {
          throw RetrySetupFailure.loginFailed
        }
        let server = try TokenAccount.normalizedServerIdentity(from: url)
        return .init(
          userID: account.serverUserId,
          serverIdentity: server,
          defaultLibraryID: nil,
          accessToken: "access",
          refreshToken: "refresh",
          accessExpiry: nil,
          cleanup: { _ in })
      },
      loginBackoffGate: loginBackoffGate)
  }
}

private enum RetrySetupFailure: Error {
  case deallocated
  case loginFailed
}

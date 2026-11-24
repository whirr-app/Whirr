import Foundation
import Testing
import WatchProtocol

@testable import Whirr

@Suite("Watch link status")
struct WatchLinkStatusTests {
  private let confirmedAt = Date(timeIntervalSinceReferenceDate: 1_000)

  private func status(_ configure: (inout WatchLinkInputs) -> Void = { _ in }) -> WatchLinkStatus {
    var inputs = WatchLinkInputs()
    configure(&inputs)
    return WatchLinkStatus(inputs)
  }

  private func confirmed(_ health: WatchLinkHealth?) -> WatchLinkConfirmation {
    WatchLinkConfirmation(health: health, at: confirmedAt)
  }

  @Test func noAccountOutranksEverything() {
    #expect(
      status {
        $0.hasAccount = false
        $0.installState = .unpaired
        $0.isAttempting = true
        $0.lastProbe = .installed(.healthy)
        $0.lastConfirmed = confirmed(.healthy)
      } == .unbound)
  }

  @Test func installPrerequisitesOutrankAnyAnswer() {
    #expect(
      status {
        $0.installState = .unpaired
        $0.lastProbe = .installed(.healthy)
      } == .notPaired)
    #expect(
      status {
        $0.installState = .appNotInstalled
        $0.isAttempting = true
      } == .appNotInstalled)
  }

  @Test func anAttemptInFlightShowsTheFormEvenOverARememberedConnection() {
    #expect(
      status {
        $0.isAttempting = true
        $0.remembersConnection = true
      } == .settingUp)
    #expect(
      status {
        $0.isAttempting = true
        $0.lastProbe = .installed(.healthy)
      } == .settingUp)
  }

  @Test func aReconnectWaitingForItsReceiptIsNotReportedAsWorking() {
    #expect(
      status {
        $0.isAwaitingReceipt = true
        $0.remembersConnection = true
        $0.lastProbe = .installed(.healthy)
      } == .awaitingReceipt)
    #expect(
      status {
        $0.isAwaitingReceipt = true
        $0.wantsReconnect = true
      } == .awaitingReceipt)
  }

  @Test func choosingToReconnectShowsTheForm() {
    #expect(
      status {
        $0.wantsReconnect = true
        $0.lastProbe = .installed(.healthy)
      } == .settingUp)
  }

  @Test func checkingWithNothingRememberedShowsProgressNotTheForm() {
    #expect(status { $0.isChecking = true } == .checking)
    #expect(
      status {
        $0.isChecking = true
        $0.lastProbe = .notInstalled
      } == .checking)
    // A remembered connection stays on screen while it is re-checked.
    #expect(
      status {
        $0.isChecking = true
        $0.remembersConnection = true
      } == .unconfirmed)
    // A record keeps its confirmed status on screen while it is re-checked.
    #expect(
      status {
        $0.isChecking = true
        $0.remembersConnection = true
        $0.lastConfirmed = confirmed(.healthy)
      } == .working)
  }

  @Test func aRejectedSignInIsTheOneInstalledStateThatAsksForReconnection() {
    let rejected = status {
      $0.lastProbe = .installed(.signInRejected)
      $0.remembersConnection = true
    }
    #expect(rejected == .signInRejected)
    #expect(rejected.primaryAction == .reconnect)
  }

  @Test func anUnreachableServerOffersOnlyACheck() {
    let unreachable = status { $0.lastProbe = .installed(.serverUnreachable) }
    #expect(unreachable == .serverUnreachable)
    #expect(unreachable.primaryAction == .checkAgain)
    #expect(!unreachable.offersReconnect)
  }

  @Test func anInstalledWatchIsWorkingWhetherOrNotItHasReportedHealth() {
    #expect(status { $0.lastProbe = .installed(.healthy) } == .working)
    #expect(status { $0.lastProbe = .installed(nil) } == .working)
  }

  @Test func aRememberedConnectionWithoutAConfirmationIsSetUpNotConnected() {
    for probe in [WatchProbeOutcome.none, .noAnswer] {
      let unconfirmed = status {
        $0.remembersConnection = true
        $0.lastProbe = probe
      }
      #expect(unconfirmed == .unconfirmed)
      #expect(unconfirmed.headline == "Set up")
      #expect(unconfirmed.explanation == WatchLinkCopy.unconfirmed)
      #expect(unconfirmed.primaryAction == .checkAgain)
      #expect(unconfirmed.rowLabel == "Set up")
    }
  }

  @Test func aSilentWatchReportsTheConfirmedRecordsHealth() {
    for probe in [WatchProbeOutcome.none, .noAnswer] {
      #expect(
        status {
          $0.lastProbe = probe
          $0.lastConfirmed = confirmed(.healthy)
        } == .working)
      #expect(
        status {
          $0.lastProbe = probe
          $0.lastConfirmed = confirmed(nil)
        } == .working)
      #expect(
        status {
          $0.lastProbe = probe
          $0.lastConfirmed = confirmed(.serverUnreachable)
        } == .serverUnreachable)
      #expect(
        status {
          $0.lastProbe = probe
          $0.lastConfirmed = confirmed(.signInRejected)
        } == .signInRejected)
    }
  }

  @Test func aLiveAnswerOverridesTheConfirmedRecord() {
    #expect(
      status {
        $0.lastProbe = .installed(.healthy)
        $0.lastConfirmed = confirmed(.signInRejected)
      } == .working)
    #expect(
      status {
        $0.lastProbe = .installed(.serverUnreachable)
        $0.lastConfirmed = confirmed(.healthy)
      } == .serverUnreachable)
    #expect(
      status {
        $0.lastProbe = .notInstalled
        $0.lastConfirmed = confirmed(.healthy)
      } == .notSetUp)
    #expect(
      status {
        $0.lastProbe = .otherAccount
        $0.lastConfirmed = confirmed(.healthy)
      } == .otherAccount)
  }

  @Test func workingLeadsWithACheckAndKeepsReconnectSecondary() {
    let working = status { $0.lastProbe = .installed(.healthy) }
    #expect(working.primaryAction == .checkAgain)
    #expect(working.offersReconnect)
  }

  @Test func anotherAccountsWatchIsNeverOfferedReconnection() {
    let foreign = status {
      $0.lastProbe = .otherAccount
      $0.remembersConnection = true
    }
    #expect(foreign == .otherAccount)
    #expect(foreign.primaryAction == .checkAgain)
    #expect(!foreign.offersReconnect)
  }

  @Test func onlyADefinitiveNotInstalledAnswerOffersSetup() {
    let fresh = status { $0.lastProbe = .notInstalled }
    #expect(fresh == .notSetUp)
    #expect(fresh.showsSetupForm)
    #expect(status { $0.wantsReconnect = true }.showsSetupForm)
  }

  @Test func noAnswerWithNothingRememberedIsUnknownNotUnprovisioned() {
    #expect(status() == .unreachable)
    #expect(status { $0.lastProbe = .noAnswer } == .unreachable)
    #expect(!status { $0.lastProbe = .noAnswer }.showsSetupForm)
    #expect(status { $0.lastProbe = .noAnswer }.primaryAction == .checkAgain)
  }

  @Test func theSettingsRowNamesTheProblem() {
    #expect(WatchLinkStatus.working.rowLabel == "Connected")
    #expect(WatchLinkStatus.unconfirmed.rowLabel == "Set up")
    #expect(WatchLinkStatus.signInRejected.rowLabel == "Needs sign-in")
    #expect(WatchLinkStatus.serverUnreachable.rowLabel == "Can’t reach server")
    #expect(WatchLinkStatus.otherAccount.rowLabel == "Different account")
    #expect(WatchLinkStatus.notSetUp.rowLabel == "Not set up")
    #expect(WatchLinkStatus.notPaired.rowLabel == "Not installed")
    #expect(WatchLinkStatus.appNotInstalled.rowLabel == "Not installed")
    for neutral in [WatchLinkStatus.unbound, .checking, .unreachable, .settingUp, .awaitingReceipt] {
      #expect(neutral.rowLabel == WatchLinkStatus.neutralRowLabel)
    }
  }

  // MARK: - Confirmation line

  @Test func theConfirmationLineCountsUpFromJustNow() {
    let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
    func line(after seconds: TimeInterval) -> String {
      WatchLinkConfirmationCopy.line(confirmedAt: now.addingTimeInterval(-seconds), now: now)
    }
    #expect(line(after: 0) == "Confirmed just now")
    #expect(line(after: 59) == "Confirmed just now")
    #expect(line(after: 60) == "Confirmed 1 min ago")
    #expect(line(after: 12 * 60) == "Confirmed 12 min ago")
    #expect(line(after: 59 * 60) == "Confirmed 59 min ago")
    #expect(line(after: 60 * 60) == "Confirmed 1 hr ago")
    #expect(line(after: 2 * 60 * 60) == "Confirmed 2 hr ago")
    #expect(line(after: 23 * 60 * 60) == "Confirmed 23 hr ago")
    #expect(line(after: 24 * 60 * 60) == "Confirmed 1 day ago")
    #expect(line(after: 48 * 60 * 60) == "Confirmed 2 days ago")
  }

  @Test func aConfirmationInTheFutureReadsAsJustNow() {
    let now = Date(timeIntervalSinceReferenceDate: 10_000_000)
    #expect(
      WatchLinkConfirmationCopy.line(
        confirmedAt: now.addingTimeInterval(90), now: now) == "Confirmed just now")
  }
}

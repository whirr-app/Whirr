import Testing
import WatchProtocol

@testable import Whirr

/// The Audiobookshelf dimension of readiness (ADR 0021).
@Suite("Watch Audiobookshelf readiness")
struct WatchABSReadinessTests {
  private let current: Set<String> = [WatchStatusCapability.enclosureFetch, WatchStatusCapability.absSend]
  private let older: Set<String> = [WatchStatusCapability.enclosureFetch]

  @Test func aWatchSignedOutOrOnAnotherAccountNeedsSettingUp() {
    for account in [WatchReportedAccount.signedOut, .otherAccount] {
      #expect(
        WatchABSReadiness(installState: .ready, reportedAccount: account, capabilities: current)
          == .setUpWatch)
    }
  }

  /// "Open Whirr on your Watch", as for RSS: an install never opened has not reported.
  @Test func aWatchNeverHeardFromIsUnknown() {
    #expect(WatchABSReadiness(installState: .ready, reportedAccount: .unknown, capabilities: nil) == .unknown)
    #expect(WatchABSReadiness(installState: .unknown, reportedAccount: .matching, capabilities: nil) == .unknown)
  }

  @Test func theCapabilityDecidesForThisAccount() {
    #expect(WatchABSReadiness(installState: .ready, reportedAccount: .matching, capabilities: current) == .ready)
    #expect(
      WatchABSReadiness(installState: .ready, reportedAccount: .matching, capabilities: older) == .needsUpdate)
    // The record outlives a relaunch; the report that filled it was this account's.
    #expect(WatchABSReadiness(installState: .ready, reportedAccount: .unknown, capabilities: current) == .ready)
  }

  @Test func aMissingAppOverridesEveryReport() {
    for state in [WatchInstallState.appNotInstalled, .unpaired] {
      #expect(
        WatchABSReadiness(installState: state, reportedAccount: .signedOut, capabilities: current)
          == .notInstalled)
      #expect(
        WatchABSReadiness(installState: state, reportedAccount: .matching, capabilities: current)
          == .notInstalled)
    }
  }

  /// The listener's choice is stored under the RSS key; books and Audiobookshelf episodes follow it
  /// rather than gaining a key of their own.
  @Test func theRemovePlayedToggleKeepsItsKey() {
    #expect(WatchEpisodeSendPreferences.removesPlayedEpisodesKey == "watch.podcasts.removePlayedEpisodes")
  }
}

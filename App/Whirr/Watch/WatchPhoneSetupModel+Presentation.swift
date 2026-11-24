import ABSApi
import AppModel
import Foundation
import Observation
import Persistence
import SyncEngine
import WatchProtocol

/// What the setup screen reads: one link status and the copy beside it. Pure reads over the
/// model's state, kept beside the attempt flow in `WatchPhoneSetupModel.swift` rather than inside
/// its stored-property declaration.
extension WatchPhoneSetupModel {
  /// The screen's single answer to whether listening on the Watch works.
  var linkStatus: WatchLinkStatus {
    WatchLinkStatus(
      WatchLinkInputs(
        hasAccount: account != nil, installState: installState,
        isAttempting: isBusy || connectInFlight || state == .connecting,
        isAwaitingReceipt: state == .waitingForReceipt, wantsReconnect: wantsReconnect,
        isChecking: isCheckingConnection, lastProbe: lastProbe, remembersConnection: connected,
        lastConfirmed: lastConfirmed))
  }

  /// When the status on screen was confirmed, or nil for a status the phone cannot date: an
  /// unconfirmed setup, an install prerequisite, or a problem the phone derived itself.
  var confirmedAt: Date? {
    switch linkStatus {
    case .working, .serverUnreachable, .signInRejected: return lastConfirmed?.at
    default: return nil
    }
  }

  /// True while a prerequisite the person must satisfy outside Whirr is unmet, so the view offers
  /// instructions in place of the password field and Connect button.
  var isBlockedOnInstall: Bool { installState == .unpaired || installState == .appNotInstalled }

  /// Whether Settings lists Apple Watch at all: only once WatchConnectivity reports a paired Watch.
  /// An iPad, or any device where `WCSession` is unsupported, never leaves `.unknown`, so it never
  /// shows the row; an iPhone with no Watch paired reports `.unpaired` and hides it too.
  var offersSettingsEntry: Bool { installState == .appNotInstalled || installState == .ready }

  var installGuidance: String? {
    switch installState {
    case .unpaired: return WatchSetupCopy.notPaired
    case .appNotInstalled: return WatchSetupCopy.appNotInstalled
    case .unknown, .ready: return nil
    }
  }

  var accountHeading: String { WatchSetupCopy.accountHeading }
  var serverLabel: String { WatchSetupCopy.serverLabel }
  var usernameLabel: String { WatchSetupCopy.usernameLabel }
  var connectedLabel: String { WatchSetupCopy.connectedLabel }
  var reconnectLabel: String { WatchSetupCopy.reconnectLabel }
  var passwordLabel: String { WatchSetupCopy.passwordLabel }
  var watchLabel: String { WatchSetupCopy.watchLabel }
  var singleSignOnExplanation: String { WatchSetupCopy.singleSignOnExplanation }

  /// An account that signs in with OpenID connects the Watch through the identity provider, so the
  /// view offers "Sign in with SSO" in place of the password field.
  var usesSingleSignOn: Bool { account?.signsInWithOpenID == true }
  var checkingConnectionLabel: String { WatchSetupCopy.checkingConnection }

  func buttonTitle(reconnecting: Bool) -> String {
    state == .waitingForReceipt
      ? WatchSetupCopy.retryLabel : reconnecting ? WatchSetupCopy.reconnectLabel : WatchSetupCopy.connectLabel
  }
}

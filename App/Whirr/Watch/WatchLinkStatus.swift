import Foundation
import WatchProtocol

/// What the phone last heard from the Watch's read-only status probe. In memory only: the
/// remembered connection and `WatchLinkRecord` are what survive a relaunch.
enum WatchProbeOutcome: Equatable {
  /// Not asked since the account was bound.
  case none
  /// No reply, an unreadable or mismatched one, or `busy`/`rejected`, none of which describe
  /// the Watch's provisioning.
  case noAnswer
  /// The Watch holds this account. Health is nil when the Watch has not yet asked its server, or
  /// is too old to report it.
  case installed(WatchLinkHealth?)
  /// The Watch holds no account.
  case notInstalled
  /// The Watch holds someone else's account.
  case otherAccount
}

/// The last status the Watch confirmed for this account, and when.
struct WatchLinkConfirmation: Equatable {
  var health: WatchLinkHealth?
  var at: Date
}

/// Everything the status derives from, gathered so the derivation is a pure function.
struct WatchLinkInputs: Equatable {
  var hasAccount = true
  var installState: WatchInstallState = .unknown
  /// A setup attempt is running: from the tap until its completion handling has finished.
  var isAttempting = false
  /// Credentials were sent but the Watch's receipt never arrived or was unclear.
  var isAwaitingReceipt = false
  /// The person chose to re-provision a Watch that already holds this account.
  var wantsReconnect = false
  var isChecking = false
  var lastProbe: WatchProbeOutcome = .none
  /// This phone install once saw the Watch confirm this account.
  var remembersConnection = false
  /// The last confirmed status for this account, from a live answer or the persisted record.
  var lastConfirmed: WatchLinkConfirmation?
}

/// The Apple Watch screen's one answer to "is listening on the Watch working, and if not, why?".
/// The setup form is shown only for `settingUp` and `notSetUp`: never as the fallback for an
/// answer the phone does not have.
enum WatchLinkStatus: Equatable {
  case unbound
  case notPaired
  case appNotInstalled
  case settingUp
  case awaitingReceipt
  case checking
  case signInRejected
  case serverUnreachable
  case working
  case otherAccount
  case notSetUp
  /// Set up on this phone, but no confirmation has arrived since the record was introduced, so
  /// the screen may not say "Connected".
  case unconfirmed
  case unreachable

  enum Action: Equatable {
    case checkAgain
    case reconnect
    case connect
    case retrySetup
  }

  /// Rows are evaluated in order and the first match wins.
  init(_ inputs: WatchLinkInputs) {
    if !inputs.hasAccount {
      self = .unbound
    } else if inputs.installState == .unpaired {
      self = .notPaired
    } else if inputs.installState == .appNotInstalled {
      self = .appNotInstalled
    } else if inputs.isAttempting {
      self = .settingUp
    } else if inputs.isAwaitingReceipt {
      // Ahead of the reconnect intent: the pending payload must be resent as it is, not replaced.
      self = .awaitingReceipt
    } else if inputs.wantsReconnect {
      self = .settingUp
    } else if inputs.isChecking && !inputs.remembersConnection {
      self = .checking
    } else {
      self = Self.derive(inputs)
    }
  }

  /// A silent probe falls back to the record, which answers exactly as a live install answer
  /// would. Only with neither does the remembered connection become "Set up" rather than
  /// "Connected".
  private static func derive(_ inputs: WatchLinkInputs) -> WatchLinkStatus {
    switch inputs.lastProbe {
    case .installed(let health): return installed(health)
    case .otherAccount: return .otherAccount
    case .notInstalled: return .notSetUp
    case .none, .noAnswer:
      if let confirmed = inputs.lastConfirmed { return installed(confirmed.health) }
      return inputs.remembersConnection ? .unconfirmed : .unreachable
    }
  }

  private static func installed(_ health: WatchLinkHealth?) -> WatchLinkStatus {
    switch health {
    case .signInRejected: return .signInRejected
    case .serverUnreachable: return .serverUnreachable
    case .healthy, .none: return .working
    }
  }

  var showsSetupForm: Bool { self == .settingUp || self == .notSetUp }

  /// The prominent control. Nil where the person can only act outside Whirr, or where the
  /// setup form supplies its own button.
  var primaryAction: Action? {
    switch self {
    case .unbound, .notPaired, .appNotInstalled, .checking, .settingUp: return nil
    case .awaitingReceipt: return .retrySetup
    case .signInRejected: return .reconnect
    case .serverUnreachable, .working, .unconfirmed, .otherAccount, .unreachable: return .checkAgain
    case .notSetUp: return .connect
    }
  }

  /// Reconnect as a secondary, confirmed choice. Only a Watch that holds this account offers it:
  /// new credentials cannot fix a network, and every layer refuses to replace another account.
  var offersReconnect: Bool {
    switch self {
    case .working, .unconfirmed: return true
    default: return false
    }
  }

  /// The sentence under the status, or nil where the screen shows something richer (the form,
  /// install guidance, progress).
  var explanation: String? {
    switch self {
    case .unbound: return WatchLinkCopy.unbound
    case .awaitingReceipt: return WatchLinkCopy.awaitingReceipt
    case .signInRejected: return WatchLinkCopy.signInRejected
    case .serverUnreachable: return WatchLinkCopy.serverUnreachable
    case .unconfirmed: return WatchLinkCopy.unconfirmed
    case .otherAccount: return WatchLinkCopy.otherAccount
    case .unreachable: return WatchLinkCopy.unreachable
    case .working, .notPaired, .appNotInstalled, .settingUp, .checking, .notSetUp: return nil
    }
  }

  var headline: String? {
    switch self {
    case .working: return WatchLinkCopy.connected
    case .signInRejected: return WatchLinkCopy.needsSignIn
    case .serverUnreachable: return WatchLinkCopy.cantReachServer
    case .otherAccount: return WatchLinkCopy.differentAccount
    case .unconfirmed: return WatchLinkCopy.setUp
    case .unreachable: return WatchLinkCopy.notResponding
    case .unbound, .notPaired, .appNotInstalled, .settingUp, .awaitingReceipt, .checking, .notSetUp: return nil
    }
  }

  static let neutralRowLabel = "Set up and check listening on your Watch"

  /// The Settings row's detail line.
  var rowLabel: String {
    switch self {
    case .working: return WatchLinkCopy.connected
    case .signInRejected: return WatchLinkCopy.needsSignIn
    case .serverUnreachable: return WatchLinkCopy.cantReachServer
    case .otherAccount: return WatchLinkCopy.differentAccount
    case .unconfirmed: return WatchLinkCopy.setUp
    case .notSetUp: return "Not set up"
    case .notPaired, .appNotInstalled: return "Not installed"
    case .unbound, .checking, .unreachable, .settingUp, .awaitingReceipt: return Self.neutralRowLabel
    }
  }
}

/// The line under a confirmed status. Hand-rolled in the screen's own units so the copy has one
/// deterministic shape, rather than varying with `RelativeDateTimeFormatter`'s locale.
enum WatchLinkConfirmationCopy {
  static func line(confirmedAt: Date, now: Date) -> String {
    let elapsed = max(0, now.timeIntervalSince(confirmedAt))
    let minutes = Int(elapsed / 60)
    if minutes < 1 { return "Confirmed just now" }
    if minutes < 60 { return "Confirmed \(minutes) min ago" }
    let hours = minutes / 60
    if hours < 24 { return "Confirmed \(hours) hr ago" }
    let days = hours / 24
    return "Confirmed \(days) \(days == 1 ? "day" : "days") ago"
  }
}

enum WatchLinkCopy {
  static let connected = "Connected"
  static let setUp = "Set up"
  static let needsSignIn = "Needs sign-in"
  static let cantReachServer = "Can’t reach server"
  static let differentAccount = "Different account"
  static let notResponding = "Not responding"
  static let unbound = "Sign in to Whirr on this iPhone first."
  static let awaitingReceipt = "The Watch didn’t confirm the sign-in."
  static let signInRejected = "The server no longer accepts the Watch’s sign-in. Reconnect to sign it in again."
  static let serverUnreachable =
    "The Watch can’t reach your server. Put it on a network that can reach the server address."
  static let unconfirmed = "Open Whirr on your Watch to confirm it’s working."
  static let otherAccount =
    "The Watch is signed in to a different account. Disconnect it in Whirr on the Watch, then check again."
  static let unreachable = "Open Whirr on your Watch. This screen updates when it answers."
  static let checkAgain = "Check Now"
  static let reconnect = "Reconnect Apple Watch"
  static let reconnectConfirmation = "This signs the Watch out and stops any downloads in progress."
  static let reconnectFooter =
    "Only needed if your Watch stops syncing. It signs the Watch in again with this account."
  static let cancel = "Cancel"
}

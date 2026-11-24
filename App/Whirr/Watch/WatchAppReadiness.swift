import WatchProtocol

/// What the phone knows about the Watch app's own capabilities from its last status report. The
/// On Apple Watch screen reads it to choose between its three not-yet-acknowledged statuses; it is
/// an App type so screens never work from the wire's capability strings.
enum WatchAppReadiness: Equatable, Sendable {
  /// No record, or a record no report has filled in yet: an install the listener has never opened,
  /// or an app too old to publish a status report.
  case unknown
  /// The Watch's report names `enclosureFetch`, so it can download an offered enclosure itself.
  case canFetch
  /// A report arrived from a Watch app that predates its own enclosure fetch.
  case needsUpdate
  /// WatchConnectivity says the Watch app is not installed, or no Watch is paired. The copies the
  /// phone still holds describe files that went with the app, so this takes precedence over any
  /// capability an earlier install reported.
  case notInstalled

  init(capabilities: Set<String>?) {
    guard let capabilities else {
      self = .unknown
      return
    }
    self = capabilities.contains(WatchStatusCapability.enclosureFetch) ? .canFetch : .needsUpdate
  }

  init(installState: WatchInstallState, capabilities: Set<String>?) {
    switch installState {
    case .appNotInstalled, .unpaired:
      self = .notInstalled
    case .unknown, .ready:
      // `.unknown` cannot assert a prerequisite, so it reads as the last report did.
      self.init(capabilities: capabilities)
    }
  }
}

/// What the Watch's latest status report said about its account, against this phone's.
/// Held in memory: the Watch's application context is replayed on every bind.
enum WatchReportedAccount: Equatable, Sendable {
  /// No report since this account was bound.
  case unknown
  case matching
  case signedOut
  case otherAccount
}

/// The Audiobookshelf dimension of readiness (ADR 0021). A Watch that fetches RSS enclosures may
/// still predate Audiobookshelf sends, and a Watch on another account (or none) takes no
/// Audiobookshelf offer from this phone, while RSS copies carry no account and keep working.
enum WatchABSReadiness: Equatable, Sendable {
  /// No report yet: an install never opened, or a report not yet replayed. "Open Whirr on your
  /// Watch", as for RSS.
  case unknown
  /// The Watch is on this account and names `absSend`.
  case ready
  /// The Watch is on this account and predates `absSend`.
  case needsUpdate
  /// The Watch app is signed out, or signed in to another account.
  case setUpWatch
  case notInstalled

  init(
    installState: WatchInstallState, reportedAccount: WatchReportedAccount,
    capabilities: Set<String>?
  ) {
    switch installState {
    case .appNotInstalled, .unpaired:
      self = .notInstalled
      return
    case .unknown, .ready:
      break
    }
    switch reportedAccount {
    case .signedOut, .otherAccount:
      self = .setUpWatch
    case .unknown, .matching:
      guard let capabilities else {
        self = .unknown
        return
      }
      self = capabilities.contains(WatchStatusCapability.absSend) ? .ready : .needsUpdate
    }
  }
}

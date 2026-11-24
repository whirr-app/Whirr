import Persistence

/// One title's copy on the Watch, in terms both the RSS and the Audiobookshelf desired sets map
/// into, so a screen never switches over either store's record (ADR 0021). It keeps every store
/// state, with the facts the On Apple Watch rows draw: who removed a copy, and why the Watch
/// declined or failed one.
public enum WatchCopyState: Sendable, Equatable {
  public enum Remover: Sendable, Equatable {
    case phone
    case watch
  }

  public enum DeclineReason: Sendable, Equatable {
    case storageFull
    case invalid
    case signedOut
  }

  /// Why the Watch could not download an Audiobookshelf title. RSS copies carry none.
  public enum FailureReason: Sendable, Equatable {
    /// The server answered with an error status, including a sign-in the Watch could not renew.
    case server
    case network
    case tooLarge
    /// The server no longer has the item or episode.
    case notOnServer
    /// The item has no audio the Watch can play.
    case noAudio
    /// A redirect, a response or a plan the Watch could not use.
    case couldNotDownload
  }

  case wanted
  case waitingForWatch
  case sending
  case delivered
  case removed(Remover)
  case declined(DeclineReason)
  case failed(FailureReason?)

  /// The canonical menu's two-way answer: a copy owed, in flight or delivered offers Remove; one
  /// the Watch removed, declined or failed offers Send, which retries it at a new revision.
  public var menuCopy: PodcastEpisodeWatchCopy {
    switch self {
    case .wanted, .waitingForWatch, .sending, .delivered: .onWatch
    case .removed, .declined, .failed: .notOnWatch
    }
  }

  /// The RSS store's row. Its state and reason columns are checked together by the schema, so a
  /// removed row always names who removed it and a declined one always says why.
  public init(
    state: RSSWatchCopyState, removedBy: RSSWatchCopyRemovalInitiator?,
    declineReason: RSSWatchDeclineReason?, failureReason: ABSWatchFailureReason? = nil
  ) {
    switch state {
    case .wanted: self = .wanted
    case .waitingForWatch: self = .waitingForWatch
    case .sending: self = .sending
    case .delivered: self = .delivered
    case .removed: self = .removed(removedBy == .watch ? .watch : .phone)
    case .declined: self = .declined(Self.decline(declineReason))
    case .failed: self = .failed(failureReason.map(Self.failure))
    }
  }

  public init(_ copy: RSSWatchCopy) {
    self.init(state: copy.state, removedBy: copy.removedBy, declineReason: copy.declineReason)
  }

  public init(_ copy: ABSWatchCopy) {
    self.init(
      state: copy.state, removedBy: copy.removedBy, declineReason: copy.declineReason,
      failureReason: copy.failureReason)
  }

  private static func decline(_ reason: RSSWatchDeclineReason?) -> DeclineReason {
    switch reason {
    case .storageFull: .storageFull
    case .signedOut: .signedOut
    case .invalid, nil: .invalid
    }
  }

  static func failure(_ reason: ABSWatchFailureReason) -> FailureReason {
    switch reason {
    case .httpStatus: .server
    case .network: .network
    case .tooLarge: .tooLarge
    case .itemMissing: .notOnServer
    case .noAudio: .noAudio
    case .insecureRedirect, .invalidResponse, .planInvalid: .couldNotDownload
    }
  }
}

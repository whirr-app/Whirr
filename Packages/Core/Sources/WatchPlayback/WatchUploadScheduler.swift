import Foundation

/// Decides when the Watch tries to upload its closed progress rows. Uploads never wait for the
/// phone: a pause, stop, launch, foreground, peer reconnect or checkpoint requests one, and a
/// transport failure with rows still pending retries in the foreground after 1, 5, then 15 minutes
/// One run at a time; a request during a run is remembered and runs once more.
public struct WatchUploadScheduler: Sendable, Equatable {
  public enum Outcome: Sendable, Equatable {
    case succeeded
    /// The server could not be reached; worth retrying while rows wait.
    case transportFailure
    /// Any other failure: retrying on a timer would fail the same way.
    case failed
  }

  public enum LogoutAttempt: Sendable, Equatable {
    case run(bound: Duration)
    case awaitRunning(bound: Duration)
  }

  public static let retryDelays: [TimeInterval] = [60, 300, 900]
  /// Continuous play this long closes and reopens the row.
  public static let checkpointInterval: TimeInterval = 600
  /// Logout waits this long at most for its one upload.
  public static let logoutBound: Duration = .seconds(10)

  public private(set) var isRunning = false
  /// When a foreground retry is due, if one is.
  public private(set) var retryAt: Date?
  private var runAgain = false
  private var transportFailures = 0
  private var closed = false
  private var playingSince: TimeInterval?

  public init() {}

  /// Returns whether to start a run now.
  public mutating func request() -> Bool {
    guard !closed else { return false }
    guard !isRunning else {
      runAgain = true
      return false
    }
    isRunning = true
    return true
  }

  /// The phone sent a catalogue. That is not a reconnect: the phone republishes on every change,
  /// and on its playhead while it plays, so a run for each would read the server and report to
  /// the phone with nothing to send. Only closed rows waiting justify one, and never during a
  /// transport backoff, which the retry timer owns. Returns whether to start a run now.
  public mutating func requestForPeerContext(pending: Bool) -> Bool {
    guard pending, retryAt == nil else { return false }
    return request()
  }

  /// A run ended; `pending` says whether rows still wait. Returns whether to run again at once.
  public mutating func finish(_ outcome: Outcome, pending: Bool, now: Date) -> Bool {
    switch outcome {
    case .transportFailure where pending:
      transportFailures += 1
      let delay = Self.retryDelays[min(transportFailures, Self.retryDelays.count) - 1]
      retryAt = now.addingTimeInterval(delay)
    case .transportFailure, .failed, .succeeded:
      transportFailures = 0
      retryAt = nil
    }
    guard runAgain, !closed else {
      runAgain = false
      isRunning = false
      return false
    }
    runAgain = false
    return true
  }

  /// A foreground check of the retry timer. Returns whether to start a run now.
  public mutating func retryIfDue(now: Date) -> Bool {
    guard let retryAt, now >= retryAt else { return false }
    self.retryAt = nil
    return request()
  }

  /// One attempt, or the one already running, and nothing after it.
  public mutating func logout() -> LogoutAttempt {
    closed = true
    retryAt = nil
    if isRunning {
      runAgain = false
      return .awaitRunning(bound: Self.logoutBound)
    }
    isRunning = true
    return .run(bound: Self.logoutBound)
  }

  /// The logout did not go through: the account is still signed in, so uploads resume.
  public mutating func reopen() {
    closed = false
  }

  /// A run ended without reporting an outcome, so it no longer holds the scheduler.
  public mutating func abandon() {
    isRunning = false
    runAgain = false
  }

  /// Audio is playing at `uptime`; the first call starts the checkpoint count.
  public mutating func playing(at uptime: TimeInterval) {
    if playingSince == nil { playingSince = uptime }
  }

  /// Audio stopped playing; the next play starts a new count.
  public mutating func stopped() {
    playingSince = nil
  }

  /// Whether continuous play has reached a checkpoint. Taking one starts the next count.
  public mutating func checkpointDue(at uptime: TimeInterval) -> Bool {
    guard let playingSince, uptime - playingSince >= Self.checkpointInterval else { return false }
    self.playingSince = uptime
    return true
  }
}

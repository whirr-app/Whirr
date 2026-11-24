import Foundation
import WatchProtocol

/// The Watch's whole outgoing application context. `updateApplicationContext` replaces the
/// dictionary rather than merging it, so the playing report and the status report must be composed
/// together: writing either one keeps the other.
public struct WatchApplicationContextComposer: Equatable, Sendable {
  public private(set) var playingReport: Data?
  public private(set) var statusReport: Data?

  public init(playingReport: Data? = nil, statusReport: Data? = nil) {
    self.playingReport = playingReport
    self.statusReport = statusReport
  }

  public mutating func setPlayingReport(_ data: Data?) {
    playingReport = data
  }

  public mutating func setStatusReport(_ data: Data?) {
    statusReport = data
  }

  /// The dictionary for `WCSession.updateApplicationContext`, holding whichever reports exist.
  public var applicationContext: [String: Any] {
    var context: [String: Any] = [:]
    if let playingReport { context[WatchPlayingReport.transportKey] = playingReport }
    if let statusReport { context[WatchStatusReport.transportKey] = statusReport }
    return context
  }
}

/// Whether the Watch should send its status report now. A status only changes when the account,
/// the link health or the capabilities do, so a fixed period keeps `reportedAt` fresh without
/// writing the context on every refresh; the phone needs the check time to stay recent.
public struct WatchStatusReportThrottle: Equatable, Sendable {
  /// The last report that was actually written to the session.
  public struct Published: Equatable, Sendable {
    public let accountStamp: WatchAccountStamp?
    public let health: WatchLinkHealth?
    public let capabilities: Set<String>
    /// When it was published, from the report's own clock.
    public let at: Date

    public init(_ report: WatchStatusReport) {
      accountStamp = report.accountStamp
      health = report.health
      capabilities = report.capabilities
      at = report.reportedAt
    }
  }

  /// The age after which an unchanged report is repeated.
  public static let interval: TimeInterval = 15 * 60

  public init() {}

  /// Publishes when nothing has been published, when the account, health or capabilities differ,
  /// or when the last publish is at least `interval` old.
  public func shouldPublish(_ report: WatchStatusReport, after last: Published?, at now: Date) -> Bool {
    guard let last else { return true }
    if last.accountStamp != report.accountStamp
      || last.health != report.health
      || last.capabilities != report.capabilities
    {
      return true
    }
    return now.timeIntervalSince(last.at) >= Self.interval
  }
}

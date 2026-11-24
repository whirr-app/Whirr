import Foundation
import WatchConnectivity
import WatchPlayback
import WatchProtocol

/// The one writer of the Watch's outgoing application context. Every update replaces the whole
/// dictionary, so the playing report and the status report are composed here rather than written
/// independently; neither can erase the other. Not observed: no screen reads it.
@MainActor
final class WatchApplicationContextPublisher {
  /// What this build can do, carried by every report so the phone can tell an up-to-date Watch
  /// from one that predates its own enclosure fetch (ADR 0020 Decision 6) or its own fetch of a
  /// phone-sent Audiobookshelf item (ADR 0021).
  static let capabilities: Set<String> = [WatchStatusCapability.enclosureFetch, WatchStatusCapability.absSend]

  private(set) var composer = WatchApplicationContextComposer()
  private let throttle = WatchStatusReportThrottle()
  private var lastPublished: WatchStatusReportThrottle.Published?
  private let session: WCSession

  init(session: WCSession = .default) {
    self.session = session
  }

  /// Returns whether the context was written, so the caller dates a playing report only when it
  /// actually shipped. The data is composed either way, so a later write carries it too.
  @discardableResult
  func publishPlayingReport(_ data: Data) -> Bool {
    composer.setPlayingReport(data)
    return write()
  }

  /// Sends the current status unless the throttle says an unchanged one is still fresh.
  func publishStatus(
    accountStamp: WatchAccountStamp?, health: WatchLinkHealth?, checkedAt: Date?, now: Date = .now
  ) {
    let checked = checkedAt == nil ? "no" : "yes"
    guard
      let report = try? WatchStatusReport(
        accountStamp: accountStamp, health: health, checkedAt: checkedAt, reportedAt: now,
        capabilities: Self.capabilities)
    else {
      WatchRSSDiagnostics.log("status_publish", ["outcome": "compose_failed", "checkedAt": checked])
      return
    }
    guard throttle.shouldPublish(report, after: lastPublished, at: now) else {
      WatchRSSDiagnostics.log("status_publish", ["outcome": "throttled", "checkedAt": checked])
      return
    }
    guard let data = try? WatchWireCodec.encode(report) else {
      WatchRSSDiagnostics.log("status_publish", ["outcome": "encode_failed", "checkedAt": checked])
      return
    }
    let previous = composer.statusReport
    composer.setStatusReport(data)
    guard write() else {
      // Nothing shipped. Restore the status the phone already holds: a later playing-report write
      // replaces the whole context, and must not drop the delivered status with it.
      WatchRSSDiagnostics.log("status_publish", ["outcome": "write_failed", "checkedAt": checked])
      composer.setStatusReport(previous)
      return
    }
    WatchRSSDiagnostics.log("status_publish", ["outcome": "sent", "checkedAt": checked])
    lastPublished = WatchStatusReportThrottle.Published(report)
  }

  private func write() -> Bool {
    guard session.activationState == .activated else { return false }
    return (try? session.updateApplicationContext(composer.applicationContext)) != nil
  }
}

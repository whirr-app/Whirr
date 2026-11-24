import Foundation

/// The title another device (the Watch) last reported playing, and when it said so. The
/// report cannot be retracted once that device is out of range, so it lapses `expiry` after
/// `observedAt`. AppModel keeps no Watch wire types: the phone's Watch glue maps the
/// Watch's playing report into this value.
public struct CompanionDevicePlayback: Sendable, Equatable {
  public static let expiry: TimeInterval = 3 * 60
  /// How far ahead of this device's clock a report may be dated and still be believed.
  public static let futureSkewTolerance: TimeInterval = 30

  public let itemID: String
  public let episodeID: String?
  public let observedAt: Date

  public init(itemID: String, episodeID: String?, observedAt: Date) {
    self.itemID = itemID
    self.episodeID = episodeID
    self.observedAt = observedAt
  }

  public var expiresAt: Date { observedAt.addingTimeInterval(Self.expiry) }

  public func isCurrent(at now: Date) -> Bool {
    let age = now.timeIntervalSince(observedAt)
    return age.isFinite && age >= -Self.futureSkewTolerance && age < Self.expiry
  }

  public func isPlaying(itemID: String, episodeID: String?) -> Bool {
    self.itemID == itemID && self.episodeID == episodeID
  }
}

extension PlaybackModel {
  /// Holds `report` until it expires, replacing any earlier one; `nil` or a stale report clears.
  public func setCompanionDevicePlayback(_ report: CompanionDevicePlayback?, now: Date = Date()) {
    companionExpiryTask?.cancel()
    companionExpiryTask = nil
    guard let report, report.isCurrent(at: now) else {
      if companionDevicePlayback != nil { companionDevicePlayback = nil }
      return
    }
    if companionDevicePlayback != report { companionDevicePlayback = report }
    let wait = report.expiresAt.timeIntervalSince(now)
    let sleep = companionExpiryWait
    companionExpiryTask = Task { [weak self] in
      await sleep(wait)
      // Only this report's own expiry clears it; a newer report cancelled this task.
      guard !Task.isCancelled, let self, self.companionDevicePlayback == report else { return }
      self.companionDevicePlayback = nil
      self.companionExpiryTask = nil
    }
  }

  /// Whether the other device is playing this title now, as far as this device knows.
  public func isPlayingOnCompanion(itemID: String, episodeID: String?) -> Bool {
    companionDevicePlayback?.isPlaying(itemID: itemID, episodeID: episodeID) ?? false
  }
}

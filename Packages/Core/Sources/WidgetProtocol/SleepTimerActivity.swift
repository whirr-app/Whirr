import Foundation

#if canImport(ActivityKit) && os(iOS)
  import ActivityKit
#endif

/// The sleep-timer Live Activity's values, shared by the app's driver,
/// which starts, updates and ends the activity, and the extension's views, which draw it.
///
/// The activity carries no title, show or item: it is drawn on the Lock Screen, and the system's
/// own Now Playing card already shows what is playing while audio is active.
public struct SleepTimerActivityAttributes: Codable, Sendable, Hashable {
  public init() {}

  public struct ContentState: Codable, Sendable, Hashable {
    public let label: SleepTimerActivityLabel
    /// Whether the timer is counting down now. It counts only while audio plays, so this is
    /// `false` while paused and through any non-playing spell the driver did not smooth over.
    public let isRunning: Bool
    /// When the timer will fire if playback carries on uninterrupted; present exactly when
    /// running, so the view can draw a system-driven countdown without updates.
    public let endsAt: Date?
    /// Time left, for the paused label. Wall-clock seconds for a countdown; for an end-of-chapter
    /// or end-of-item timer, media seconds divided by the playback rate.
    public let remainingSeconds: Double
    /// Only a countdown can be extended; an end-of-chapter or end-of-item timer cannot.
    public let canExtend: Bool
    /// The last `SleepTimerFade.windowSeconds` of a countdown, while the volume fades.
    public let isFading: Bool

    public init(
      label: SleepTimerActivityLabel,
      isRunning: Bool,
      endsAt: Date?,
      remainingSeconds: Double,
      canExtend: Bool,
      isFading: Bool
    ) throws {
      self.label = label
      self.isRunning = isRunning
      self.endsAt = endsAt
      self.remainingSeconds = remainingSeconds
      self.canExtend = canExtend
      self.isFading = isFading
      try validate()
    }

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.label = try container.decode(SleepTimerActivityLabel.self, forKey: .label)
      self.isRunning = try container.decode(Bool.self, forKey: .isRunning)
      self.endsAt = try container.decodeIfPresent(Date.self, forKey: .endsAt)
      self.remainingSeconds = try container.decode(Double.self, forKey: .remainingSeconds)
      self.canExtend = try container.decode(Bool.self, forKey: .canExtend)
      self.isFading = try container.decode(Bool.self, forKey: .isFading)
      try validate()
    }

    public func validate() throws {
      guard remainingSeconds.isFinite, remainingSeconds >= 0, isRunning == (endsAt != nil) else {
        throw WidgetProtocolError.invalidValue
      }
      if let endsAt, !endsAt.timeIntervalSinceReferenceDate.isFinite {
        throw WidgetProtocolError.invalidValue
      }
      if label != .countdown, canExtend || isFading {
        throw WidgetProtocolError.invalidValue
      }
    }

    private enum CodingKeys: String, CodingKey {
      case label, isRunning, endsAt, remainingSeconds, canExtend, isFading
    }
  }
}

public enum SleepTimerActivityLabel: String, Codable, Sendable, Hashable {
  case countdown
  case endOfChapter
  case endOfEpisode
  case endOfBook
}

#if canImport(ActivityKit) && os(iOS)
  extension SleepTimerActivityAttributes: ActivityAttributes {}
#endif

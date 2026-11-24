import Foundation

/// One received RSS episode's progress on the Watch. The rules match `WatchPendingProgressEntry`
/// so a native listen is admitted by the same bounds as an ABS one.
public struct WatchNativeProgressEntry: Codable, Sendable, Equatable {
  public let selection: WatchNativeSelection
  public let position: Double
  /// When the listener last played or sought this episode on the Watch; the phone compares it
  /// with the row's own `updatedAt`.
  public let lastListenedAt: Date
  public let isFinished: Bool
  public let duration: Double?

  public init(
    selection: WatchNativeSelection, position: Double, lastListenedAt: Date, isFinished: Bool, duration: Double?
  ) throws {
    self.selection = selection
    self.position = position
    self.lastListenedAt = lastListenedAt
    self.isFinished = isFinished
    self.duration = duration
    try validate()
  }

  public func validate() throws {
    try selection.validate()
    guard position.isFinite, position >= 0, position <= WatchHandoffLimits.maxPositionSeconds,
      lastListenedAt.timeIntervalSinceReferenceDate.isFinite,
      duration.map({ $0.isFinite && $0 > 0 && $0 <= WatchHandoffLimits.maxPositionSeconds }) ?? true
    else { throw WatchProtocolCodingError.invalidValue }
  }
}

/// The Watch's native progress, on its own key so it never competes with the ABS pending report.
/// It carries no account stamp because native RSS state is device-owned (ADR 0004); the phone
/// accepts it only from the install identity its copies belong to, and applies it through the
/// same writer as a local listen. The phone keeps the highest `sequence`.
public struct WatchNativeProgressReport: WatchWireValue, Equatable {
  public static let transportKey = WatchTransportKey.nativeProgressReport
  public static let maxWireBytes = WatchPendingProgressLimits.maxWireBytes
  public let version: Int
  public let watchInstallID: String
  public let sequence: UInt64
  public let entries: [WatchNativeProgressEntry]

  public init(watchInstallID: String, sequence: UInt64, entries: [WatchNativeProgressEntry]) throws {
    self.version = WatchProtocolVersion.current
    self.watchInstallID = watchInstallID
    self.sequence = sequence
    self.entries = entries
    try validate()
  }

  public func validate() throws {
    guard version == WatchProtocolVersion.current else {
      throw WatchProtocolCodingError.unsupportedVersion(version)
    }
    try WatchInstallIdentity.validate(watchInstallID)
    guard entries.count <= WatchPendingProgressLimits.maxEntries else {
      throw WatchProtocolCodingError.tooManyRows
    }
    guard Set(entries.map(\.selection)).count == entries.count else {
      throw WatchProtocolCodingError.invalidValue
    }
    for entry in entries { try entry.validate() }
  }
}

/// A phone start for an episode the Watch reports playing. It asks the Watch to pause and answer
/// with its position; the phone then starts there, as it does for an Audiobookshelf title. A timeout means
/// the phone starts from its own position rather than waiting.
public struct WatchNativePauseRequest: WatchWireValue, Equatable {
  public static let transportKey = WatchTransportKey.nativePauseRequest
  public static let maxWireBytes = WatchHandoffLimits.maxWireBytes
  public let version: Int
  public let selection: WatchNativeSelection
  public let sentAt: Date

  public init(selection: WatchNativeSelection, sentAt: Date = Date()) throws {
    self.version = WatchProtocolVersion.current
    self.selection = selection
    self.sentAt = sentAt
    try validate()
  }

  public func validate() throws {
    guard version == WatchProtocolVersion.current else {
      throw WatchProtocolCodingError.unsupportedVersion(version)
    }
    try selection.validate()
    guard sentAt.timeIntervalSinceReferenceDate.isFinite else {
      throw WatchProtocolCodingError.invalidValue
    }
  }
}

/// The Watch's answer to a `WatchNativePauseRequest`. `paused == false` says the Watch was not
/// playing that episode, and then carries no position: the phone keeps its own.
public struct WatchNativePauseReply: WatchWireValue, Equatable {
  public static let transportKey = WatchTransportKey.nativePauseRequest
  public static let maxWireBytes = WatchHandoffLimits.maxWireBytes
  public let version: Int
  public let selection: WatchNativeSelection
  public let paused: Bool
  public let position: Double?
  public let lastListenedAt: Date?

  public init(
    selection: WatchNativeSelection, paused: Bool, position: Double? = nil, lastListenedAt: Date? = nil
  ) throws {
    self.version = WatchProtocolVersion.current
    self.selection = selection
    self.paused = paused
    self.position = position
    self.lastListenedAt = lastListenedAt
    try validate()
  }

  public func validate() throws {
    guard version == WatchProtocolVersion.current else {
      throw WatchProtocolCodingError.unsupportedVersion(version)
    }
    try selection.validate()
    if let position {
      guard position.isFinite, position >= 0, position <= WatchHandoffLimits.maxPositionSeconds else {
        throw WatchProtocolCodingError.invalidValue
      }
    }
    if let lastListenedAt {
      guard lastListenedAt.timeIntervalSinceReferenceDate.isFinite else {
        throw WatchProtocolCodingError.invalidValue
      }
    }
    guard paused || (position == nil && lastListenedAt == nil) else {
      throw WatchProtocolCodingError.invalidValue
    }
  }
}

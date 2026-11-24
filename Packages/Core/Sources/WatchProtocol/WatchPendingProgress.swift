import Foundation

public enum WatchPendingProgressLimits {
  /// Matches the Watch's upload batch, so a report never names more titles than one upload sends.
  public static let maxEntries = 50
  public static let maxDownloaded = WatchProtocolVersion.maxRows
  public static let maxWireBytes = 16 * 1024
}

/// One title's progress the Watch holds and has not uploaded yet.
public struct WatchPendingProgressEntry: Codable, Sendable, Equatable {
  public let selection: WatchABSSelection
  public let position: Double
  /// When the listener last played or sought this title on the Watch; the rule compares it with
  /// the phone's own timestamp for the title.
  public let lastListenedAt: Date
  public let isFinished: Bool
  public let duration: Double?

  public init(
    selection: WatchABSSelection, position: Double, lastListenedAt: Date, isFinished: Bool, duration: Double?
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

/// The Watch's latest view of the progress it has not uploaded, and of the titles it holds. It
/// travels by `transferUserInfo`, never the application context, which the ownership
/// advertisement already owns. The phone keeps only the highest `sequence` it has seen.
public struct WatchPendingProgressReport: WatchWireValue, Equatable {
  public static let transportKey = WatchTransportKey.pendingProgressReport
  public static let maxWireBytes = WatchPendingProgressLimits.maxWireBytes
  public let version: Int
  public let accountStamp: WatchAccountStamp
  public let sequence: UInt64
  public let entries: [WatchPendingProgressEntry]
  public let downloaded: [WatchABSSelection]

  public init(
    accountStamp: WatchAccountStamp, sequence: UInt64, entries: [WatchPendingProgressEntry],
    downloaded: [WatchABSSelection]
  ) throws {
    self.version = WatchProtocolVersion.current
    self.accountStamp = accountStamp
    self.sequence = sequence
    self.entries = entries
    self.downloaded = downloaded
    try validate()
  }

  public func validate() throws {
    guard version == WatchProtocolVersion.current else { throw WatchProtocolCodingError.unsupportedVersion(version) }
    try accountStamp.validate()
    guard entries.count <= WatchPendingProgressLimits.maxEntries,
      downloaded.count <= WatchPendingProgressLimits.maxDownloaded
    else { throw WatchProtocolCodingError.tooManyRows }
    for entry in entries { try entry.validate() }
    for selection in downloaded { try selection.validate() }
    guard Set(entries.map(\.selection)).count == entries.count, Set(downloaded).count == downloaded.count else {
      throw WatchProtocolCodingError.invalidValue
    }
  }

  public func entry(itemID: String, episodeID: String?) -> WatchPendingProgressEntry? {
    entries.first { $0.selection.itemID == itemID && $0.selection.episodeID == episodeID }
  }

  /// The Watch's position for a phone start, when the offline rule picks it over what the phone
  /// last knew for the title; `nil` leaves the phone's own start position in place. A title the
  /// Watch finished starts again from the beginning, as it does on the Watch.
  public func startPosition(
    itemID: String, episodeID: String?, sharedPosition: Double?, sharedUpdatedAt: Date?, now: Date = Date()
  ) -> Double? {
    guard let entry = entry(itemID: itemID, episodeID: episodeID) else { return nil }
    let resolution = WatchOfflineConflictPolicy.resolve(
      watchPosition: entry.position, watchListenedAt: entry.lastListenedAt,
      sharedPosition: sharedPosition, sharedUpdatedAt: sharedUpdatedAt, duration: entry.duration, now: now)
    guard resolution?.winner == .watch else { return nil }
    return entry.isFinished ? 0 : entry.position
  }
}

/// Sent by the phone before it starts a title the Watch reported. The Watch tries to upload, then
/// answers with its current `WatchPendingProgressReport`.
public struct WatchPendingProgressQuery: WatchWireValue, Equatable {
  public static let transportKey = WatchTransportKey.pendingProgressQuery
  public static let maxWireBytes = WatchHandoffLimits.maxWireBytes
  public let version: Int
  public let accountStamp: WatchAccountStamp
  public let selection: WatchABSSelection

  public init(accountStamp: WatchAccountStamp, selection: WatchABSSelection) throws {
    self.version = WatchProtocolVersion.current
    self.accountStamp = accountStamp
    self.selection = selection
    try validate()
  }

  public func validate() throws {
    guard version == WatchProtocolVersion.current else { throw WatchProtocolCodingError.unsupportedVersion(version) }
    try accountStamp.validate()
    try selection.validate()
  }
}

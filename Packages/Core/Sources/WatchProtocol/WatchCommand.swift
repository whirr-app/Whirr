import Foundation

public enum WatchCommandAction: String, Codable, Sendable, Equatable {
  case play
  case pause
  case resume
  case seek
  case skip
  case setRate
}

/// A command is admitted for processing, not proof that audio has started.
public struct WatchCommand: WatchWireValue, Equatable, Identifiable {
  public static let maxWireBytes = WatchProtocolVersion.maxCommandBytes
  public let version: Int
  public let id: UUID
  public let accountStamp: WatchAccountStamp
  public let selection: WatchSelection
  public let action: WatchCommandAction
  public let value: Double?
  public let issuedAt: Date

  public init(
    id: UUID = UUID(),
    accountStamp: WatchAccountStamp,
    selection: WatchSelection,
    action: WatchCommandAction = .play,
    value: Double? = nil,
    issuedAt: Date = Date()
  ) throws {
    try selection.validate()
    try Self.validate(action: action, value: value)
    guard issuedAt.timeIntervalSinceReferenceDate.isFinite else {
      throw WatchProtocolCodingError.invalidValue
    }
    self.version = WatchProtocolVersion.current
    self.id = id
    self.accountStamp = accountStamp
    self.selection = selection
    self.action = action
    self.value = value
    self.issuedAt = issuedAt
  }

  public func validate() throws {
    try accountStamp.validate()
    guard version == WatchProtocolVersion.current else {
      throw WatchProtocolCodingError.unsupportedVersion(version)
    }
    try selection.validate()
    try Self.validate(action: action, value: value)
    guard issuedAt.timeIntervalSinceReferenceDate.isFinite else {
      throw WatchProtocolCodingError.invalidValue
    }
  }

  private static func validate(action: WatchCommandAction, value: Double?) throws {
    switch action {
    case .play:
      // Continue on iPhone names where the Watch paused; any other start names nothing.
      if let value { guard value.isFinite, value >= 0 else { throw WatchProtocolCodingError.invalidValue } }
    case .pause, .resume:
      guard value == nil else { throw WatchProtocolCodingError.invalidValue }
    case .seek:
      guard let value, value.isFinite, value >= 0 else { throw WatchProtocolCodingError.invalidValue }
    case .skip:
      guard let value, value.isFinite, value != 0, abs(value) <= 300 else {
        throw WatchProtocolCodingError.invalidValue
      }
    case .setRate:
      guard let value, value.isFinite,
        (WatchProtocolVersion.minimumPlaybackRate...WatchProtocolVersion.maximumPlaybackRate).contains(value)
      else { throw WatchProtocolCodingError.invalidValue }
    }
  }

  /// A deterministic identity for deduplication. It contains no credentials or transport data.
  public func fingerprint() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try String(decoding: encoder.encode(self), as: UTF8.self)
  }

  private enum CodingKeys: String, CodingKey { case version, id, accountStamp, selection, action, value, issuedAt }
}

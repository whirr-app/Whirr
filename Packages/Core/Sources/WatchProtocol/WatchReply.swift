import Foundation

public enum WatchReplyStatus: String, Codable, Sendable, Equatable {
  case accepted
  case rejected
}

public struct WatchReply: WatchWireValue, Equatable {
  public static let maxWireBytes = 8 * 1024
  public let version: Int
  public let commandID: UUID
  public let status: WatchReplyStatus
  public let errorCode: WatchProtocolErrorCode?

  public init(
    commandID: UUID,
    status: WatchReplyStatus,
    errorCode: WatchProtocolErrorCode? = nil
  ) throws {
    guard status == .accepted ? errorCode == nil : errorCode != nil else {
      throw WatchProtocolCodingError.invalidValue
    }
    self.version = WatchProtocolVersion.current
    self.commandID = commandID
    self.status = status
    self.errorCode = errorCode
  }

  public static func accepted(commandID: UUID) -> WatchReply {
    try! WatchReply(commandID: commandID, status: .accepted)
  }

  public static func rejected(
    commandID: UUID,
    errorCode: WatchProtocolErrorCode
  ) -> WatchReply {
    try! WatchReply(commandID: commandID, status: .rejected, errorCode: errorCode)
  }

  public func matches(commandID: UUID) -> Bool { self.commandID == commandID }
  public func matches(_ command: WatchCommand) -> Bool { matches(commandID: command.id) }

  private enum CodingKeys: String, CodingKey { case version, commandID, status, errorCode }
  public func validate() throws {
    guard version == WatchProtocolVersion.current else {
      throw WatchProtocolCodingError.unsupportedVersion(version)
    }
    guard status == .accepted ? errorCode == nil : errorCode != nil else {
      throw WatchProtocolCodingError.invalidValue
    }
  }
}

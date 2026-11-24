import Foundation

/// The immutable ordering token carried by every synced podcast mutation.
public struct PodcastCloudMutationStamp: Codable, Sendable, Hashable, Comparable {
  public let physicalMilliseconds: Int64
  public let logicalCounter: Int64
  public let installationUUID: UUID
  public let mutationUUID: UUID

  public static let bottom = try! PodcastCloudMutationStamp(
    physicalMilliseconds: 0, logicalCounter: 0,
    installationUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
    mutationUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
  )

  public init(
    physicalMilliseconds: Int64, logicalCounter: Int64,
    installationUUID: UUID, mutationUUID: UUID
  ) throws {
    guard physicalMilliseconds >= 0, logicalCounter >= 0 else { throw ValidationError.invalidClock }
    self.physicalMilliseconds = physicalMilliseconds
    self.logicalCounter = logicalCounter
    self.installationUUID = installationUUID
    self.mutationUUID = mutationUUID
  }

  public enum ValidationError: Error, Sendable, Equatable { case invalidClock }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      physicalMilliseconds: c.decode(Int64.self, forKey: .physicalMilliseconds),
      logicalCounter: c.decode(Int64.self, forKey: .logicalCounter),
      installationUUID: c.decode(UUID.self, forKey: .installationUUID),
      mutationUUID: c.decode(UUID.self, forKey: .mutationUUID))
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    if lhs.physicalMilliseconds != rhs.physicalMilliseconds {
      return lhs.physicalMilliseconds < rhs.physicalMilliseconds
    }
    if lhs.logicalCounter != rhs.logicalCounter { return lhs.logicalCounter < rhs.logicalCounter }
    if lhs.installationUUID.uuidString != rhs.installationUUID.uuidString {
      return lhs.installationUUID.uuidString < rhs.installationUUID.uuidString
    }
    return lhs.mutationUUID.uuidString < rhs.mutationUUID.uuidString
  }
}

import Foundation

/// Whole LWW saved membership, including the durable removal marker.
public struct PodcastCloudSavedRegister: Codable, Sendable, Equatable {
  public let isSaved: Bool
  public let savedAt: Date?
  public let stamp: PodcastCloudMutationStamp

  public init(isSaved: Bool, savedAt: Date? = nil, stamp: PodcastCloudMutationStamp) throws {
    guard isSaved == (savedAt != nil), savedAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true else {
      throw ValidationError.inconsistentValue
    }
    self.isSaved = isSaved
    self.savedAt = savedAt
    self.stamp = stamp
  }
  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      isSaved: values.decode(Bool.self, forKey: .isSaved),
      savedAt: values.decodeIfPresent(Date.self, forKey: .savedAt),
      stamp: values.decode(PodcastCloudMutationStamp.self, forKey: .stamp))
  }

  public static func merge(_ lhs: Self, _ rhs: Self) throws -> Self {
    if lhs.stamp != rhs.stamp { return lhs.stamp > rhs.stamp ? lhs : rhs }
    guard lhs == rhs else { throw ValidationError.stampCollision }
    return lhs
  }
  public enum ValidationError: Error, Sendable, Equatable { case inconsistentValue, stampCollision }
}

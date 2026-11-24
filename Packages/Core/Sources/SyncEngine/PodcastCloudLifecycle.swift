import Foundation

/// The parent follow register. A generation change fences every child value.
public struct PodcastCloudFollowRegister: Codable, Sendable, Equatable {
  public let subscriptionUUID: UUID
  public let generationUUID: UUID
  public let isFollowed: Bool
  public let stamp: PodcastCloudMutationStamp

  public init(
    subscriptionUUID: UUID, generationUUID: UUID, isFollowed: Bool,
    stamp: PodcastCloudMutationStamp
  ) {
    self.subscriptionUUID = subscriptionUUID
    self.generationUUID = generationUUID
    self.isFollowed = isFollowed
    self.stamp = stamp
  }

  public static func merge(_ lhs: Self, _ rhs: Self) throws -> Self {
    guard lhs.subscriptionUUID == rhs.subscriptionUUID else { throw ValidationError.subscriptionMismatch }
    if lhs.stamp != rhs.stamp { return lhs.stamp > rhs.stamp ? lhs : rhs }
    guard lhs == rhs else { throw ValidationError.stampCollision }
    return lhs
  }
  public enum ValidationError: Error, Sendable, Equatable { case subscriptionMismatch, stampCollision }
  public func acceptsChild(generationUUID: UUID) -> Bool { isFollowed && self.generationUUID == generationUUID }
}

public struct PodcastCloudChildReference: Codable, Sendable, Equatable {
  public let subscriptionUUID: UUID
  public let generationUUID: UUID
  public init(subscriptionUUID: UUID, generationUUID: UUID) {
    self.subscriptionUUID = subscriptionUUID
    self.generationUUID = generationUUID
  }
  public func isAdmitted(by parent: PodcastCloudFollowRegister) -> Bool {
    subscriptionUUID == parent.subscriptionUUID && parent.acceptsChild(generationUUID: generationUUID)
  }
}

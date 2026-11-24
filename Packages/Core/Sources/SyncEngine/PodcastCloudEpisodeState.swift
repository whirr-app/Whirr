import Foundation

/// A complete episode intent. Merge always returns one whole value.
public struct PodcastCloudEpisodeState: Codable, Sendable, Equatable {
  public let position: Double
  public let isFinished: Bool
  public let isDismissed: Bool
  public let explicitEpoch: PodcastCloudMutationStamp
  public let writeStamp: PodcastCloudMutationStamp

  public init(
    position: Double, isFinished: Bool, isDismissed: Bool,
    explicitEpoch: PodcastCloudMutationStamp = .bottom,
    writeStamp: PodcastCloudMutationStamp
  ) throws {
    guard position.isFinite && position >= 0, explicitEpoch <= writeStamp else { throw ValidationError.invalidValue }
    self.position = position
    self.isFinished = isFinished
    self.isDismissed = isDismissed
    self.explicitEpoch = explicitEpoch
    self.writeStamp = writeStamp
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      position: values.decode(Double.self, forKey: .position),
      isFinished: values.decode(Bool.self, forKey: .isFinished),
      isDismissed: values.decode(Bool.self, forKey: .isDismissed),
      explicitEpoch: values.decode(PodcastCloudMutationStamp.self, forKey: .explicitEpoch),
      writeStamp: values.decode(PodcastCloudMutationStamp.self, forKey: .writeStamp))
  }

  public static func merge(_ lhs: Self, _ rhs: Self) throws -> Self {
    if lhs.writeStamp == rhs.writeStamp, lhs != rhs { throw ValidationError.stampCollision }
    if lhs.explicitEpoch != rhs.explicitEpoch { return lhs.explicitEpoch > rhs.explicitEpoch ? lhs : rhs }
    if lhs.writeStamp != rhs.writeStamp { return lhs.writeStamp > rhs.writeStamp ? lhs : rhs }
    guard lhs == rhs else { throw ValidationError.stampCollision }
    return lhs
  }
  public enum ValidationError: Error, Sendable, Equatable { case invalidValue, stampCollision }
}

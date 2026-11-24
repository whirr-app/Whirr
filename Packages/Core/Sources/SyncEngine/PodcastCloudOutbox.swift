import Foundation

/// Namespace fence attached to an outbox send and its acknowledgement.
public struct PodcastCloudAccountFence: Codable, Sendable, Equatable, Hashable {
  public let container: String
  public let environment: String
  public let zone: String
  public let iCloudUserRecordID: String?
  public let accountEpoch: Int64

  public init(
    container: String, environment: String, zone: String,
    iCloudUserRecordID: String?, accountEpoch: Int64
  ) {
    self.container = container
    self.environment = environment
    self.zone = zone
    self.iCloudUserRecordID = iCloudUserRecordID
    self.accountEpoch = accountEpoch
  }
}

public struct PodcastCloudOutboxSend: Codable, Sendable, Equatable {
  public let recordName: String
  public let generation: Int64
  public let fence: PodcastCloudAccountFence?

  public init(recordName: String, generation: Int64, fence: PodcastCloudAccountFence?) {
    self.recordName = recordName
    self.generation = generation
    self.fence = fence
  }

  /// ACKs are accepted only for the exact send and account namespace still current.
  public func acceptsAcknowledgement(
    currentRecordName: String, currentGeneration: Int64, currentFence: PodcastCloudAccountFence?
  ) -> Bool {
    guard let fence, let user = fence.iCloudUserRecordID, !user.isEmpty else { return false }
    return generation >= 0 && fence.accountEpoch >= 0 && !recordName.isEmpty
      && currentRecordName == recordName && fence == currentFence && generation == currentGeneration
  }
}

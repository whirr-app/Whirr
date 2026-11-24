import ABSApi
import Foundation
import SyncEngine

nonisolated extension BackgroundDownloadSessionAdapter {
  struct PersistedTaskMetadata: Codable {
    let identity: TransferIdentity
    let destinationURL: URL
    let redirectPolicy: TransferRedirectPolicy
    let hopCount: Int
    let effectiveByteLimit: Int64?

    init(
      identity: TransferIdentity, destinationURL: URL, redirectPolicy: TransferRedirectPolicy = .abs, hopCount: Int = 0,
      effectiveByteLimit: Int64? = nil
    ) {
      self.identity = identity
      self.destinationURL = destinationURL
      self.redirectPolicy = redirectPolicy
      self.hopCount = hopCount
      self.effectiveByteLimit = effectiveByteLimit
    }

    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      if let identity = try values.decodeIfPresent(TransferIdentity.self, forKey: .identity) {
        self.identity = identity
      } else {
        let id = try values.decode(Int64.self, forKey: .downloadId)
        self.identity = .abs(rowID: id)
      }
      self.destinationURL = try values.decode(URL.self, forKey: .destinationURL)
      self.redirectPolicy = try values.decodeIfPresent(TransferRedirectPolicy.self, forKey: .redirectPolicy) ?? .abs
      self.hopCount = try values.decodeIfPresent(Int.self, forKey: .hopCount) ?? 0
      self.effectiveByteLimit = try values.decodeIfPresent(Int64.self, forKey: .effectiveByteLimit)
    }

    func encode(to encoder: Encoder) throws {
      var values = encoder.container(keyedBy: CodingKeys.self)
      try values.encode(identity, forKey: .identity)
      try values.encode(destinationURL, forKey: .destinationURL)
      try values.encode(redirectPolicy, forKey: .redirectPolicy)
      try values.encode(hopCount, forKey: .hopCount)
      try values.encodeIfPresent(effectiveByteLimit, forKey: .effectiveByteLimit)
    }

    private enum CodingKeys: String, CodingKey {
      case identity, downloadId, destinationURL, redirectPolicy, hopCount, effectiveByteLimit
    }
  }
}

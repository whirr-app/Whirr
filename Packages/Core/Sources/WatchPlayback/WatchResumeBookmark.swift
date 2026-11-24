import Foundation
import WatchProtocol

/// Where the Watch will pick a title up after relaunch. Both sources are valid: a native-feed
/// episode plays from a Watch-local copy, so its bookmark is no less resumable than an
/// Audiobookshelf one.
public struct WatchResumeBookmark: Codable, Sendable {
  public let accountStamp: WatchAccountStamp
  public let selection: WatchSelection
  public let position: Double
  public init(accountStamp: WatchAccountStamp, selection: WatchSelection, position: Double) throws {
    try selection.validate()
    guard position.isFinite, (0...WatchHandoffLimits.maxPositionSeconds).contains(position) else {
      throw WatchHandoffError.invalidValue
    }
    self.accountStamp = accountStamp
    self.selection = selection
    self.position = position
  }
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      accountStamp: container.decode(WatchAccountStamp.self, forKey: .accountStamp),
      selection: container.decode(WatchSelection.self, forKey: .selection),
      position: container.decode(Double.self, forKey: .position))
  }
}

import Foundation

/// Errors are coarse. They are safe to surface to a paired UI and do not contain
/// server, URL, credential, or audio-engine details.
public enum WatchHandoffError: Error, Codable, Sendable, Equatable {
  case invalidValue
  case invalidSelection
  case nativeSelectionRejected
}

/// The only selection one device can name to the other in a handoff, or in pending progress.
/// Native RSS is absent from this type so neither value can imply Watch-local RSS playback; the
/// playing report names an RSS episode only through its own separate native field, and Watch-local
/// playability is derived on the Watch from a received copy, never claimed on the wire (ADR 0019).
public struct WatchABSSelection: Codable, Sendable, Equatable, Hashable {
  public let itemID: String
  public let episodeID: String?

  public init(itemID: String, episodeID: String?) throws {
    self.itemID = itemID
    self.episodeID = episodeID
    try validate()
  }

  /// Rejects a native-feed selection: handoff and pending progress stay ABS-only. Native episodes
  /// travel as `WatchNativeSelection` on their own keys instead (ADR 0019).
  public init(selection: WatchSelection) throws {
    guard case .audiobookshelf(let itemID, let episodeID) = selection else {
      throw WatchHandoffError.nativeSelectionRejected
    }
    try self.init(itemID: itemID, episodeID: episodeID)
  }

  public var watchSelection: WatchSelection {
    .audiobookshelf(itemID: itemID, episodeID: episodeID)
  }

  private enum CodingKeys: String, CodingKey { case itemID, episodeID }
  public func validate() throws {
    let selection = WatchSelection.audiobookshelf(itemID: itemID, episodeID: episodeID)
    guard (try? selection.validate()) != nil else {
      throw WatchHandoffError.invalidSelection
    }
  }
}

public enum WatchHandoffLimits {
  public static let maxPositionSeconds = 7.0 * 24.0 * 60.0 * 60.0
  public static let maxWireBytes = 8 * 1024
}

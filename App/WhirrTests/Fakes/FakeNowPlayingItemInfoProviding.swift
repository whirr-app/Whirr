import ABSApi
import AVFoundation
import MediaPlayer
import PlayerCore
import SyncEngine

@testable import Whirr

/// Test double for `NowPlayingItemInfoProviding`: a canned lookup keyed by item ID, standing in
/// for the library data the real provider will read.
@MainActor
final class FakeNowPlayingItemInfoProviding: NowPlayingItemInfoProviding {
  var infoByItemID: [String: NowPlayingItemInfo] = [:]

  /// Every episode id this double was asked about. An audiobook test can then assert it was asked
  /// with `nil`, not just that the title came back at item level.
  private(set) var requestedEpisodeIDs: [String?] = []

  func nowPlayingItemInfo(forItemID itemID: String) -> NowPlayingItemInfo? {
    infoByItemID[itemID]
  }

  /// Keyed by item by design, since this double stands in for library data with no episode rows.
  /// The episode id is recorded, not resolved. The protocol has no default forwarding, so ignoring
  /// episode scope must be a visible choice.
  func nowPlayingItemInfo(forItemID itemID: String, episodeID: String?) -> NowPlayingItemInfo? {
    requestedEpisodeIDs.append(episodeID)
    return infoByItemID[itemID]
  }
}

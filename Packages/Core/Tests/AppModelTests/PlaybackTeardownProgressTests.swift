import Foundation
import Persistence
import PlayerCore
import Testing

@testable import AppModel

/// The final RSS position a stop records: the rule that keeps teardown from erasing or
/// un-finishing real listening.
@Suite("Playback teardown progress")
struct PlaybackTeardownProgressTests {
  private static let rssItem = PodcastSourceIdentity.rss(feedId: 7)!.itemId
  private static let absItem = PodcastSourceIdentity.abs(itemId: "li_abs")!.itemId

  private static func capture(
    itemID: String = rssItem, episodeID: String = "ep-1",
    loadedItemID: String? = rssItem, loadedEpisodeID: String? = "ep-1",
    playhead: Double = 120, currentTime: Double = 100, phase: PlayerPhase = .playing
  ) -> PlaybackTeardownProgress? {
    PlaybackTeardownProgress.capture(
      itemID: itemID, episodeID: episodeID, loadedItemID: loadedItemID,
      loadedEpisodeID: loadedEpisodeID, playhead: playhead, currentTime: currentTime, phase: phase)
  }

  @Test("records the larger of the playhead and the last recorded position")
  func takesTheLargerPosition() {
    #expect(Self.capture(playhead: 120, currentTime: 100)?.currentTime == 120)
    #expect(Self.capture(playhead: 3, currentTime: 100)?.currentTime == 100)
  }

  @Test("ignores a non-finite reading and records nothing when neither is finite")
  func dropsNonFiniteReadings() {
    #expect(Self.capture(playhead: .nan, currentTime: 100)?.currentTime == 100)
    #expect(Self.capture(playhead: .infinity, currentTime: 40)?.currentTime == 40)
    #expect(Self.capture(playhead: .nan, currentTime: .nan) == nil)
  }

  @Test("clamps a negative position to zero")
  func clampsNegativePositions() {
    #expect(Self.capture(playhead: -5, currentTime: -2)?.currentTime == 0)
  }

  @Test("is finished only when the player reached the end")
  func finishedFromEnded() {
    #expect(Self.capture(phase: .ended)?.isFinished == true)
    #expect(Self.capture(phase: .paused)?.isFinished == false)
    #expect(Self.capture(phase: .playing)?.isFinished == false)
  }

  @Test("records nothing for an identity the player has not loaded")
  func requiresTheLoadedIdentity() {
    #expect(Self.capture(loadedItemID: nil) == nil)
    #expect(Self.capture(loadedItemID: PodcastSourceIdentity.rss(feedId: 8)!.itemId) == nil)
    #expect(Self.capture(loadedEpisodeID: "ep-2") == nil)
    #expect(Self.capture(loadedEpisodeID: nil) == nil)
  }

  @Test("records nothing for an Audiobookshelf item")
  func requiresAnRSSItem() {
    #expect(
      Self.capture(itemID: Self.absItem, loadedItemID: Self.absItem) == nil)
  }

  @Test("carries the identity it captured")
  func carriesIdentity() {
    #expect(
      Self.capture()
        == PlaybackTeardownProgress(
          itemID: Self.rssItem, episodeID: "ep-1", currentTime: 120, isFinished: false))
  }
}

import AppModel
import Foundation
import Testing
import WatchProtocol

@testable import Whirr

struct CompanionDeviceIndicatorPresentationTests {
  @Test func itShowsOnlyWhileTheWatchPlaysATitleThisPhoneIsNot() {
    #expect(CompanionDeviceIndicatorPresentation.shows(watchPlaying: true, playingHere: false))
    #expect(!CompanionDeviceIndicatorPresentation.shows(watchPlaying: true, playingHere: true))
    #expect(!CompanionDeviceIndicatorPresentation.shows(watchPlaying: false, playingHere: false))
  }

  /// A playing report names the title and keeps the Watch's own time; a paused report clears it.
  @MainActor
  @Test func theRuntimeMapsOnlyAPlayingReport() throws {
    let stamp = try WatchAccountStamp(accountIdentityHash: "account", serverIdentityHash: "server")
    let observed = Date(timeIntervalSinceReferenceDate: 100)
    let selection = try WatchABSSelection(itemID: "show", episodeID: "episode")
    let playing = try WatchPlayingReport(
      accountStamp: stamp, selection: selection, playing: true, observedAt: observed)
    #expect(
      WatchCompanionRuntime.companionPlayback(playing)
        == CompanionDevicePlayback(itemID: "show", episodeID: "episode", observedAt: observed))

    let paused = try WatchPlayingReport(
      accountStamp: stamp, selection: selection, playing: false, observedAt: observed)
    #expect(WatchCompanionRuntime.companionPlayback(paused) == nil)
  }
}

import AppModel
import Foundation
import Testing

@testable import Whirr

@Suite("Look Back menu entry and copy")
struct PlayerLookBackPresentationTests {
  @Test("offered for the loaded audiobook only, downloaded or not")
  func offeredForTheLoadedAudiobook() {
    #expect(
      PlayerLookBackPresentation.isOffered(
        itemID: "book", episodeID: nil, loadedItemID: "book", loadedEpisodeID: nil,
        isRestoredAudiobook: false))
    // Another item is loaded: the page's book has no playhead to look back from.
    #expect(
      PlayerLookBackPresentation.isOffered(
        itemID: "book", episodeID: nil, loadedItemID: "other", loadedEpisodeID: nil,
        isRestoredAudiobook: false) == false)
    #expect(
      PlayerLookBackPresentation.isOffered(
        itemID: "book", episodeID: nil, loadedItemID: nil, loadedEpisodeID: nil,
        isRestoredAudiobook: false) == false)
    // Episodes have Transcript instead.
    #expect(
      PlayerLookBackPresentation.isOffered(
        itemID: "show", episodeID: "ep", loadedItemID: "show", loadedEpisodeID: "ep",
        isRestoredAudiobook: false) == false)
  }

  @Test("offered for a cold launch's restored audiobook before its first Play")
  func offeredForTheRestoredAudiobook() {
    #expect(
      PlayerLookBackPresentation.isOffered(
        itemID: "book", episodeID: nil, loadedItemID: nil, loadedEpisodeID: nil,
        isRestoredAudiobook: true))
    #expect(
      PlayerLookBackPresentation.isOffered(
        itemID: "show", episodeID: "ep", loadedItemID: nil, loadedEpisodeID: nil,
        isRestoredAudiobook: true) == false)
  }

  @Test("a sleep-timer pause makes the tip pending once, for the next open")
  func tipTriggerIsConsumedOnce() throws {
    let defaults = try #require(UserDefaults(suiteName: "LookBackTipTrigger.\(UUID().uuidString)"))
    #expect(LookBackTipTrigger.consumePending(in: defaults) == false)
    LookBackTipTrigger.recordSleepTimerPause(in: defaults)
    #expect(LookBackTipTrigger.consumePending(in: defaults))
    #expect(LookBackTipTrigger.consumePending(in: defaults) == false)
  }

  @Test("one progress cue while working: the transcribing wave animates in place of a spinner")
  func oneProgressCue() {
    #expect(LookBackWorkingIndicator(for: .transcribing) == .animatedSymbol)
    // A still symbol has nothing moving, so the spinner carries the progress.
    #expect(LookBackWorkingIndicator(for: .waiting) == .spinner)
    #expect(LookBackWorkingIndicator(for: .installingAsset) == .spinner)
  }

  @Test("its own menu symbol, not Add to Up Next's")
  func menuSymbol() {
    #expect(LookBackCopy.playingFrom("\u{2212}4:10") == "Playing from \u{2212}4:10")
  }

  @Test("timestamps count back from where Look Back opened, never reading nearer than they are")
  func timestampsCountBack() {
    #expect(TranscriptTimestamp.text(before: 4_000, start: 3_100) == "\u{2212}15:00")
    #expect(TranscriptTimestamp.text(before: 4_000, start: 3_987.4) == "\u{2212}0:13")
    #expect(TranscriptTimestamp.text(before: 4_000, start: 4_000) == "\u{2212}0:00")
    #expect(TranscriptTimestamp.text(before: 4_000, start: 200) == "\u{2212}1:03:20")
  }

  @Test("a download under way is offered again, and a device without a recogniser is told")
  func assetStates() {
    #expect(LookBackComposition.assetState(.installed) == .installed)
    #expect(LookBackComposition.assetState(.notInstalled) == .downloadable)
    #expect(LookBackComposition.assetState(.downloading) == .downloadable)
    #expect(LookBackComposition.assetState(.unavailable) == .unsupported)
  }
}

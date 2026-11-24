import Foundation
import Testing

@testable import WidgetProtocol

@Suite struct WidgetControlPresentationTests {

  private func snapshot(isPlaying: Bool?, skipBackSeconds: Int = 30) throws -> WidgetSnapshot {
    try WidgetSnapshot(
      generatedAt: WidgetFixtures.generatedAt, accountStamp: WidgetFixtures.stamp(),
      nowPlaying: isPlaying.map { try WidgetNowPlaying(token: nil, isPlaying: $0) },
      skipBackSeconds: skipBackSeconds)
  }

  @Test func toggleIsOffWithoutASnapshotOrPlayback() throws {
    #expect(!WidgetControlPresentation.isPlaying(nil))
    #expect(!WidgetControlPresentation.isPlaying(.signedOut(generatedAt: WidgetFixtures.generatedAt)))
    #expect(!WidgetControlPresentation.isPlaying(try snapshot(isPlaying: nil)))
  }

  @Test func toggleFollowsTheSnapshotsPlayingFlag() throws {
    #expect(WidgetControlPresentation.isPlaying(try snapshot(isPlaying: true)))
    #expect(!WidgetControlPresentation.isPlaying(try snapshot(isPlaying: false)))
  }

  @Test func offeredIntervalsPassThroughAndNameTheirSymbol() {
    for interval in WidgetSnapshotLimits.skipIntervals {
      #expect(WidgetControlPresentation.skipBackSeconds(interval) == interval)
      #expect(WidgetControlPresentation.skipBackSymbolName(seconds: interval) == "gobackward.\(interval)")
      #expect(WidgetControlPresentation.skipBackLabel(seconds: interval) == "Back \(interval) s")
    }
  }

  @Test func missingOrUnofferedIntervalsFallBackToFifteen() throws {
    for bad in [nil, 0, -15, 20, 91, Int.max, Int.min] as [Int?] {
      #expect(WidgetControlPresentation.skipBackSeconds(bad) == 15)
    }
    #expect(WidgetControlPresentation.skipBackSymbolName(seconds: 20) == "gobackward.15")
    #expect(WidgetControlPresentation.skipBackLabel(seconds: 20) == "Back 15 s")
    #expect(WidgetControlPresentation.skipBackSeconds(nil as WidgetSnapshot?) == 15)
    #expect(WidgetControlPresentation.skipBackSeconds(try snapshot(isPlaying: nil, skipBackSeconds: 45)) == 45)
  }

  @Test func playPauseSymbolAndTextMatchTheValue() {
    #expect(WidgetControlPresentation.playPauseSymbolName(isPlaying: false) == "play.fill")
    #expect(WidgetControlPresentation.playPauseSymbolName(isPlaying: true) == "pause.fill")
    #expect(WidgetControlPresentation.playPauseValueText(isPlaying: false) == "Paused")
    #expect(WidgetControlPresentation.playPauseValueText(isPlaying: true) == "Playing")
  }
}

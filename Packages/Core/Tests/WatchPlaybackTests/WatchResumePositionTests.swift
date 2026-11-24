import Foundation
import Testing

@testable import WatchPlayback

@Suite struct WatchResumePositionTests {
  private let base = Date(timeIntervalSince1970: 1_800_000_000)

  private func at(_ position: Double, _ offset: TimeInterval?) -> WatchResumePosition.Candidate {
    WatchResumePosition.Candidate(position: position, listenedAt: offset.map { base.addingTimeInterval($0) })
  }

  @Test func newerSharedListeningBeatsAStaleWatchPosition() {
    // The Watch stopped at 10 minutes; the phone then listened on to 30 minutes.
    let start = WatchResumePosition.start(handoff: nil, local: [at(600, 0)], shared: at(1_800, 1_200))
    #expect(start == 1_800)
  }

  @Test func newerWatchListeningBeatsOlderSharedProgress() {
    let start = WatchResumePosition.start(handoff: nil, local: [at(900, 600)], shared: at(300, 0))
    #expect(start == 900)
  }

  @Test func aConfirmedHandoffAlwaysWins() {
    let start = WatchResumePosition.start(handoff: 42, local: [at(900, 600)], shared: at(1_800, 1_200))
    #expect(start == 42)
  }

  @Test func theNewestLocalCandidateRepresentsTheWatch() {
    let start = WatchResumePosition.start(
      handoff: nil, local: [at(100, 0), at(700, 900)], shared: at(400, 300))
    #expect(start == 700)
  }

  @Test func undatedWatchPositionDefersToTheServer() {
    let start = WatchResumePosition.start(handoff: nil, local: [at(600, nil)], shared: at(1_800, 0))
    #expect(start == 1_800)
  }

  @Test func undatedSharedProgressDoesNotOverrideDatedWatchListening() {
    let start = WatchResumePosition.start(handoff: nil, local: [at(600, 0)], shared: at(1_800, nil))
    #expect(start == 600)
  }

  @Test func fallsBackToWhicheverSourceExists() {
    #expect(WatchResumePosition.start(handoff: nil, local: [], shared: at(1_800, 0)) == 1_800)
    #expect(WatchResumePosition.start(handoff: nil, local: [at(600, 0)], shared: nil) == 600)
    #expect(WatchResumePosition.start(handoff: nil, local: [], shared: nil) == 0)
  }

  /// The Watch's own upload lands on the server after its last listen, so a later server
  /// timestamp at the same position is the Watch's echo, not newer listening elsewhere.
  @Test func anEchoOfTheWatchsOwnUploadDoesNotSupersede() {
    let local = at(600, 0)
    #expect(!WatchResumePosition.sharedSupersedes(local: local, shared: at(600.5, 30)))
    #expect(WatchResumePosition.start(handoff: nil, local: [local], shared: at(600.5, 30)) == 600)
  }

  @Test func supersedesOnlyWhenNewerAndElsewhere() {
    let local = at(600, 100)
    #expect(WatchResumePosition.sharedSupersedes(local: local, shared: at(1_800, 200)))
    #expect(!WatchResumePosition.sharedSupersedes(local: local, shared: at(1_800, 50)))
    #expect(!WatchResumePosition.sharedSupersedes(local: local, shared: nil))
    // Rewinding on the phone is newer listening too.
    #expect(WatchResumePosition.sharedSupersedes(local: local, shared: at(60, 200)))
  }

  @Test func aFinishedWatchTitleStartsFromZero() {
    let finished = WatchResumePosition.Candidate(position: 3_600, listenedAt: base, finished: true)
    #expect(WatchResumePosition.start(handoff: nil, local: [finished], shared: nil) == 0)
  }

  @Test func aConfirmedHandoffBeatsAFinishedWatchTitle() {
    let finished = WatchResumePosition.Candidate(position: 3_600, listenedAt: base, finished: true)
    #expect(WatchResumePosition.start(handoff: 42, local: [finished], shared: nil) == 42)
  }

  @Test func aNewerSharedPositionBeatsAFinishedWatchTitle() {
    let finished = WatchResumePosition.Candidate(position: 3_600, listenedAt: base, finished: true)
    #expect(WatchResumePosition.start(handoff: nil, local: [finished], shared: at(120, 500)) == 120)
  }

  @Test func aTitleFinishedElsewhereStartsFromZero() {
    let finishedElsewhere = WatchResumePosition.Candidate(
      position: 3_600, listenedAt: base.addingTimeInterval(500), finished: true)
    #expect(WatchResumePosition.start(handoff: nil, local: [at(600, 100)], shared: finishedElsewhere) == 0)
    #expect(WatchResumePosition.start(handoff: nil, local: [], shared: finishedElsewhere) == 0)
  }

  @Test func onlyTheWinningWatchCandidatesFinishedFlagCounts() {
    let oldFinished = WatchResumePosition.Candidate(position: 3_600, listenedAt: base, finished: true)
    let newer = at(700, 900)
    #expect(WatchResumePosition.start(handoff: nil, local: [oldFinished, newer], shared: nil) == 700)
  }
}

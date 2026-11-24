import PlayerCore
import Testing

@testable import Whirr

@Suite("Sleep timer restart banner wording")
struct SleepTimerRestartPresentationTests {
  @Test("a countdown names the length it restarted at")
  func countdownNamesLength() {
    let timer = SleepTimerState(
      mode: .countdown(remainingSeconds: 1_799), configuredSeconds: 1_800, restartedOnResume: true)
    #expect(SleepTimerRestartPresentation.message(for: timer) == "Sleep timer restarted for 30 min")
  }

  @Test("a boundary timer says only that it restarted")
  func boundaryTimerIsPlain() {
    let timer = SleepTimerState(mode: .endOfChapter(atPosition: 3_000), restartedOnResume: true)
    #expect(SleepTimerRestartPresentation.message(for: timer) == "Sleep timer restarted")
  }

  @Test("a custom length under a minute says only that it restarted")
  func shortCustomIsPlain() {
    let timer = SleepTimerState(
      mode: .countdown(remainingSeconds: 30), configuredSeconds: 30, restartedOnResume: true)
    #expect(SleepTimerRestartPresentation.message(for: timer) == "Sleep timer restarted")
  }
}

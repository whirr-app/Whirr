import Foundation
import Testing

@testable import WidgetProtocol

@Suite struct SleepTimerActivityTests {
  private typealias State = SleepTimerActivityAttributes.ContentState
  private let endsAt = Date(timeIntervalSinceReferenceDate: 815_001_800)

  @Test func runningCarriesAnEndTimeAndPausedDoesNot() throws {
    _ = try State(
      label: .countdown, isRunning: true, endsAt: endsAt, remainingSeconds: 1_800, canExtend: true,
      isFading: false)
    _ = try State(
      label: .countdown, isRunning: false, endsAt: nil, remainingSeconds: 1_800, canExtend: true,
      isFading: false)
    #expect(throws: WidgetProtocolError.invalidValue) {
      try State(
        label: .countdown, isRunning: true, endsAt: nil, remainingSeconds: 1_800, canExtend: true,
        isFading: false)
    }
    #expect(throws: WidgetProtocolError.invalidValue) {
      try State(
        label: .countdown, isRunning: false, endsAt: endsAt, remainingSeconds: 1_800,
        canExtend: true, isFading: false)
    }
  }

  /// End of chapter is fixed when the timer is set and end of item is stored the same way, so
  /// neither can be extended by a fixed amount, and neither fades on a countdown's schedule.
  @Test func onlyACountdownExtendsOrFades() throws {
    for label in [SleepTimerActivityLabel.endOfChapter, .endOfEpisode, .endOfBook] {
      _ = try State(
        label: label, isRunning: true, endsAt: endsAt, remainingSeconds: 600, canExtend: false,
        isFading: false)
      #expect(throws: WidgetProtocolError.invalidValue) {
        try State(
          label: label, isRunning: true, endsAt: endsAt, remainingSeconds: 600, canExtend: true,
          isFading: false)
      }
      #expect(throws: WidgetProtocolError.invalidValue) {
        try State(
          label: label, isRunning: true, endsAt: endsAt, remainingSeconds: 10, canExtend: false,
          isFading: true)
      }
    }
  }

  @Test func remainingTimeIsFiniteAndNonNegative() {
    for remaining in [-1, Double.nan, .infinity] {
      #expect(throws: WidgetProtocolError.invalidValue) {
        try State(
          label: .countdown, isRunning: false, endsAt: nil, remainingSeconds: remaining,
          canExtend: true, isFading: false)
      }
    }
  }

  /// ActivityKit encodes the state itself and caps it at 4 KB; decoding re-validates, so a state
  /// that could not have been built cannot be drawn either.
  @Test func stateRoundTripsWellInsideActivityKitsLimitAndRevalidates() throws {
    let state = try State(
      label: .endOfChapter, isRunning: true, endsAt: endsAt, remainingSeconds: 754.5,
      canExtend: false, isFading: false)
    let data = try JSONEncoder().encode(state)
    #expect(data.count < 512)
    #expect(try JSONDecoder().decode(State.self, from: data) == state)

    let text = try #require(String(data: data, encoding: .utf8))
    let tampered = text.replacingOccurrences(of: "\"canExtend\":false", with: "\"canExtend\":true")
    #expect(tampered != text)
    #expect(throws: WidgetProtocolError.invalidValue) {
      try JSONDecoder().decode(State.self, from: Data(tampered.utf8))
    }
  }
}

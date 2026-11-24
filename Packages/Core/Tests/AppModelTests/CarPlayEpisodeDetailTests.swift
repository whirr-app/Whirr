import Foundation
import Testing

@testable import AppModel

/// The second line of a car episode row.
@Suite struct CarPlayEpisodeDetailTests {
  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()
  /// 2026-11-13 12:00 UTC.
  private static let now = Date(timeIntervalSince1970: 1_794_571_200)

  private static func detail(
    daysAgo: Int? = 10, duration: Double? = 2_700, progress: Double = 0, finished: Bool = false
  ) -> CarPlayEpisodeDetail {
    CarPlayEpisodeDetail(
      publishedAt: daysAgo.map { now.addingTimeInterval(Double(-$0) * 86_400) }, durationSeconds: duration,
      progressSeconds: progress, isFinished: finished, now: now, calendar: calendar)
  }

  @Test func anUnstartedEpisodeSaysWhenItCameOutAndHowLongItIs() {
    let detail = Self.detail()

    #expect(detail.text == "Nov 3 · 45 min")
    #expect(detail.progress == nil)
  }

  @Test func aPartPlayedEpisodeSaysWhatIsLeft() {
    let detail = Self.detail(daysAgo: 1, progress: 900)

    #expect(detail.text == "Yesterday · 30 min left")
    #expect(detail.progress == 900.0 / 2_700.0)
  }

  @Test func aFinishedEpisodeSaysPlayedWhateverItsPosition() {
    let detail = Self.detail(daysAgo: 0, progress: 100, finished: true)

    #expect(detail.text == "Today · Played")
    #expect(detail.progress == 1)
  }

  @Test func insideTheLastMinuteTheLengthIsShownInsteadOfARemainder() {
    let detail = Self.detail(progress: 2_690)

    #expect(detail.text == "Nov 3 · 45 min")
    #expect(detail.progress == 2_690.0 / 2_700.0)
  }

  @Test func missingFactsAreLeftOutRatherThanGuessed() {
    #expect(Self.detail(daysAgo: nil).text == "45 min")
    #expect(Self.detail(duration: nil, progress: 50).text == "Nov 3")
    #expect(Self.detail(duration: nil, progress: 50).progress == nil)
    #expect(Self.detail(daysAgo: nil, duration: 0).text == nil)
  }
}

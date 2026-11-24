import Testing

@testable import AppModel

/// One duration/remainder wording owner. The pinned strings here are the ones the app's surfaces
/// already showed, except the chapter rounding the audit named.
@Suite struct DurationTextTests {

  @Test(
    "long speech is hours and minutes, truncating, with a minute floor for a positive duration",
    arguments: [
      (0.0, "0 min"), (1.0, "1 min"), (59.0, "1 min"), (60.0, "1 min"), (90.0, "1 min"),
      (3_599.0, "59 min"), (3_600.0, "1 hr"), (3_660.0, "1 hr 1 min"), (5_700.0, "1 hr 35 min"),
      (7_200.0, "2 hr"), (28_800.0, "8 hr"), (Double.nan, "0 min"), (.infinity, "0 min"),
      (-5.0, "0 min"),
    ]
  )
  func longFormatting(seconds: Double, expected: String) {
    #expect(DurationText.long(seconds) == expected)
  }

  @Test(
    "compact speech rounds to the nearest minute",
    arguments: [
      (0.0, "0m"), (30.0, "<1m"), (59.9, "<1m"), (60.0, "1m"), (90.0, "2m"),
      (749.0, "12m"), (3_540.0, "59m"), (3_599.0, "1h"), (3_600.0, "1h"),
      (11_520.0, "3h 12m"), (288_000.0, "80h"), (Double.nan, "0m"), (-1.0, "0m"),
    ]
  )
  func compactFormatting(seconds: Double, expected: String) {
    #expect(DurationText.compact(seconds) == expected)
  }

  @Test func remainingAppendsTheWordLeft() {
    #expect(DurationText.remaining(288_000) == "80h 0m left")
    #expect(DurationText.remaining(30) == "<1m left")
    #expect(DurationText.remaining(0) == "0m left")
  }

  @Test("a 90-second chapter reads one minute, never two")
  func chapterAndLengthAgreeAtNinetySeconds() {
    #expect(DurationText.long(90) == "1 min")
  }
}

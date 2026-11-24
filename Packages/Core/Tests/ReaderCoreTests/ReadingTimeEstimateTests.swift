import Testing

@testable import ReaderCore

@Suite("Reading time estimate")
struct ReadingTimeEstimateTests {

  @Test("chapter end skips a nested entry at the same progression")
  func chapterEndSkipsNestedEntryAtTheSameProgression() {
    let toc = [
      TOCEntry(title: "Chapter 1", depth: 0, startProgression: 0.2),
      TOCEntry(title: "Section 1", depth: 1, startProgression: 0.2),
      TOCEntry(title: "Chapter 2", depth: 0, startProgression: 0.7),
    ]

    #expect(ReadingTime.chapterEndProgression(in: toc, currentIndex: 0) == 0.7)
  }

  @Test("chapter end skips an unresolved entry")
  func chapterEndSkipsUnresolvedEntry() {
    let toc = [
      TOCEntry(title: "Chapter 1", depth: 0, startProgression: 0.2),
      TOCEntry(title: "Unresolved", depth: 1),
      TOCEntry(title: "Chapter 2", depth: 0, startProgression: 0.7),
    ]

    #expect(ReadingTime.chapterEndProgression(in: toc, currentIndex: 0) == 0.7)
  }

  @Test("chapter end is absent for invalid or terminal entries")
  func chapterEndIsAbsentForInvalidOrTerminalEntries() {
    let toc = [
      TOCEntry(title: "Unresolved", depth: 0),
      TOCEntry(title: "Chapter", depth: 0, startProgression: 0.4),
    ]

    #expect(ReadingTime.chapterEndProgression(in: toc, currentIndex: -1) == nil)
    #expect(ReadingTime.chapterEndProgression(in: toc, currentIndex: 2) == nil)
    #expect(ReadingTime.chapterEndProgression(in: toc, currentIndex: 0) == nil)
    #expect(ReadingTime.chapterEndProgression(in: toc, currentIndex: 1) == nil)
  }

  @Test("estimate converts remaining progression into seconds")
  func estimateConvertsRemainingProgressionIntoSeconds() {
    let estimate = ReadingTime.estimate(
      totalProgression: 0.25,
      chapterEndProgression: 0.5,
      positionCount: 100,
      wordsPerPosition: 100,
      wordsPerMinute: 100)

    #expect(estimate == ReadingTimeEstimate(chapterSeconds: 1_500, bookSeconds: 4_500))
  }

  @Test("estimate clamps both remainders at zero")
  func estimateClampsBothRemaindersAtZero() {
    let estimate = ReadingTime.estimate(
      totalProgression: 0.8,
      chapterEndProgression: 0.5,
      positionCount: 100,
      wordsPerPosition: 100,
      wordsPerMinute: 100)

    #expect(estimate.chapterSeconds == 0)
    #expect(abs((estimate.bookSeconds ?? 0) - 1_200) < 0.000_001)
  }

  @Test("estimate omits both values when positions are unavailable")
  func estimateOmitsBothValuesWhenPositionsAreUnavailable() {
    for positionCount in [0, -1] {
      let estimate = ReadingTime.estimate(
        totalProgression: 0.25,
        chapterEndProgression: 0.5,
        positionCount: positionCount)

      #expect(estimate == ReadingTimeEstimate(chapterSeconds: nil, bookSeconds: nil))
    }
  }
}

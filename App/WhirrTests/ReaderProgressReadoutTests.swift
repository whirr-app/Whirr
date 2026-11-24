import AppModel
import Testing

@testable import Whirr

@Suite("Reader progress readout")
@MainActor
struct ReaderProgressReadoutTests {
  private func progress(page: Int?, pageCount: Int?, chapterTime: String?) -> ReaderProgressDisplay {
    ReaderProgressDisplay(
      text: "", pageText: nil, percentText: "28%", percentage: 0.28,
      chapterTitle: "Chapter 3", page: page, pageCount: pageCount,
      chapterTimeRemainingText: chapterTime, bookTimeRemainingText: "About 3 hr left in book")
  }

  @Test("the widest line comes first, then the page shortens before the estimate is dropped")
  func linesNarrowInOrder() {
    let readout = ReaderProgressReadout.make(
      progress: progress(page: 112, pageCount: 402, chapterTime: "14 min left in chapter"))

    #expect(
      readout.lines == [
        .init(position: "Page 112 of 402 · 28%", trailing: "14 min left in chapter"),
        .init(position: "112 of 402 · 28%", trailing: "14 min left in chapter"),
        .init(position: "Page 112 of 402 · 28%", trailing: nil),
        .init(position: "112 of 402 · 28%", trailing: nil),
      ])
  }

  @Test("without a chapter estimate the readout is the position alone")
  func noEstimateGivesThePositionAlone() {
    let readout = ReaderProgressReadout.make(
      progress: progress(page: 112, pageCount: 402, chapterTime: nil))

    #expect(
      readout.lines == [
        .init(position: "Page 112 of 402 · 28%", trailing: nil),
        .init(position: "112 of 402 · 28%", trailing: nil),
      ])
  }

  @Test("without pages the readout is the percentage, offered once")
  func noPagesGivesThePercentage() {
    let readout = ReaderProgressReadout.make(
      progress: progress(page: nil, pageCount: nil, chapterTime: nil))

    #expect(readout.lines == [.init(position: "28%", trailing: nil)])
  }

  @Test("the book estimate never stands in for the chapter's")
  func bookEstimateIsNotShown() {
    let readout = ReaderProgressReadout.make(
      progress: progress(page: 112, pageCount: 402, chapterTime: nil))

    #expect(readout.lines.allSatisfy { $0.trailing == nil })
  }

  @Test("a scrub names the target page with its chapter, never the current estimate")
  func scrubbingNamesTheChapter() {
    let readout = ReaderProgressReadout.make(
      scrubbing: progress(page: 112, pageCount: 402, chapterTime: "14 min left in chapter"))

    #expect(readout.isScrubbing)
    #expect(
      readout.lines == [
        .init(position: "Page 112 of 402 · 28%", trailing: "Chapter 3"),
        .init(position: "112 of 402 · 28%", trailing: "Chapter 3"),
        .init(position: "Page 112 of 402 · 28%", trailing: nil),
        .init(position: "112 of 402 · 28%", trailing: nil),
      ])
  }
}

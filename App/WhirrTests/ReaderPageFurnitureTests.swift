import AppModel
import ReaderCore
import Testing

@testable import Whirr

@Suite("Reader page furniture")
@MainActor
struct ReaderPageFurnitureTests {
  private func progress(
    chapter: String?, isChapterOpening: Bool = false, pageText: String?,
    chapterTimeLeft: String? = nil
  ) -> ReaderProgressDisplay {
    ReaderProgressDisplay(
      text: "", pageText: pageText, percentText: "21%", percentage: 0.21,
      chapterTitle: chapter, isChapterOpening: isChapterOpening, page: nil, pageCount: nil,
      chapterTimeRemainingText: chapterTimeLeft, bookTimeRemainingText: nil)
  }

  private func furniture(
    _ display: ReaderProgressDisplay, footerReadout: ReaderFooterReadout = .page
  ) -> ReaderPageFurniture? {
    ReaderPageFurniture.make(
      isReading: true, isReflowable: true, isScrollMode: false, bookTitle: "The Book",
      footerReadout: footerReadout, progress: display)
  }

  private var everyReadout: ReaderProgressDisplay {
    progress(chapter: "Chapter 3", pageText: "Page 7 of 290", chapterTimeLeft: "12 min left in chapter")
  }

  @Test("the header names the chapter and the footer gives the page")
  func headerIsTheChapterAndFooterIsThePage() {
    let furniture = furniture(progress(chapter: "Chapter 3", pageText: "Page 7 of 290"))

    #expect(furniture?.header(chromeVisible: false) == "Chapter 3")
    #expect(furniture?.footer == "Page 7 of 290")
  }

  @Test("without a chapter or pages the header falls back to the book and the footer to percent")
  func fallsBackToTheBookTitleAndPercent() {
    let furniture = furniture(progress(chapter: nil, pageText: nil))

    #expect(furniture?.header(chromeVisible: false) == "The Book")
    #expect(furniture?.footer == "21%")
  }

  @Test("a chapter's opening page has no header, since the book sets its own heading there")
  func chapterOpeningHasNoHeader() {
    let furniture = furniture(
      progress(chapter: "Chapter 3", isChapterOpening: true, pageText: "Page 7 of 290"))

    #expect(furniture != nil)
    #expect(furniture?.header(chromeVisible: false) == nil)
  }

  @Test("the header names the book while the chrome shows, even on a chapter's opening page")
  func headerIsTheBookUnderTheChrome() {
    let midChapter = furniture(progress(chapter: "Chapter 3", pageText: "Page 8 of 290"))
    let opening = furniture(
      progress(chapter: "Chapter 3", isChapterOpening: true, pageText: "Page 7 of 290"))

    #expect(midChapter?.header(chromeVisible: true) == "The Book")
    #expect(opening?.header(chromeVisible: true) == "The Book")
  }

  @Test("fixed-layout books and unopened books have no furniture")
  func noFurnitureForFixedLayoutOrBeforeReading() {
    let display = progress(chapter: "Chapter 3", pageText: "Page 7 of 290")
    #expect(
      ReaderPageFurniture.make(
        isReading: true, isReflowable: false, isScrollMode: false, bookTitle: "The Book",
        footerReadout: .page, progress: display) == nil)
    #expect(
      ReaderPageFurniture.make(
        isReading: false, isReflowable: true, isScrollMode: false, bookTitle: "The Book",
        footerReadout: .page, progress: display) == nil)
  }

  @Test("scroll mode has no furniture, since the text scrolls through the margins it would sit in")
  func noFurnitureInScrollMode() {
    let display = progress(chapter: "Chapter 3", pageText: "Page 7 of 290")
    #expect(
      ReaderPageFurniture.make(
        isReading: true, isReflowable: true, isScrollMode: true, bookTitle: "The Book",
        footerReadout: .page, progress: display) == nil)
  }

  @Test("a footer tap steps from the page to the chapter's time left, to percent, and back")
  func footerTapCyclesThroughEveryReadout() {
    let page = furniture(everyReadout, footerReadout: .page)
    let time = furniture(everyReadout, footerReadout: .chapterTimeLeft)
    let percent = furniture(everyReadout, footerReadout: .percent)

    #expect(page?.footer == "Page 7 of 290")
    #expect(page?.nextFooterReadout == .chapterTimeLeft)
    #expect(time?.footer == "12 min left in chapter")
    #expect(time?.nextFooterReadout == .percent)
    #expect(percent?.footer == "21%")
    #expect(percent?.nextFooterReadout == .page)
  }

  @Test("a readout the page cannot give is skipped, both when chosen and when cycling")
  func unavailableReadoutFallsBackToTheNextOne() {
    let noChapterTime = progress(chapter: "Chapter 3", pageText: "Page 7 of 290")
    let chosenTime = furniture(noChapterTime, footerReadout: .chapterTimeLeft)
    #expect(chosenTime?.footer == "21%")
    #expect(chosenTime?.nextFooterReadout == .page)
    #expect(furniture(noChapterTime, footerReadout: .page)?.nextFooterReadout == .percent)

    let noPages = progress(
      chapter: "Chapter 3", pageText: nil, chapterTimeLeft: "12 min left in chapter")
    let chosenPage = furniture(noPages, footerReadout: .page)
    #expect(chosenPage?.footer == "12 min left in chapter")
    #expect(chosenPage?.nextFooterReadout == .percent)
    #expect(furniture(noPages, footerReadout: .percent)?.nextFooterReadout == .chapterTimeLeft)
  }

  @Test("with only one readout available the footer has nothing to cycle to")
  func singleReadoutHasNoNext() {
    for chosen in ReaderFooterReadout.allCases {
      let only = furniture(progress(chapter: nil, pageText: nil), footerReadout: chosen)
      #expect(only?.footer == "21%")
      #expect(only?.nextFooterReadout == nil)
    }
  }

  @Test("only the footer takes a tap, and only while it shows and has somewhere to go")
  func footerTakesTapOnlyWhenVisibleAndCyclable() {
    #expect(ReaderPageFurnitureView.isHitTestable == false)
    #expect(ReaderPageFurnitureView.footerTakesTap(chromeVisible: false, canCycle: true))
    #expect(ReaderPageFurnitureView.footerTakesTap(chromeVisible: true, canCycle: true) == false)
    #expect(ReaderPageFurnitureView.footerTakesTap(chromeVisible: false, canCycle: false) == false)
  }

  @Test("the footer gives way to the progress rail while the chrome shows")
  func footerHidesUnderTheChrome() {
    #expect(ReaderPageFurnitureView.showsFooter(chromeVisible: false))
    #expect(ReaderPageFurnitureView.showsFooter(chromeVisible: true) == false)
  }
}

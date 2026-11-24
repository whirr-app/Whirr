import Testing

@testable import Whirr

@Suite("Transcript ad-break stepping bar")
struct TranscriptAdBreakBarTests {
  @Test("counts the breaks until one is in view, then says which")
  func title() {
    #expect(TranscriptAdBreakBar.title(current: nil, count: 4) == "4 Ad Breaks")
    #expect(TranscriptAdBreakBar.title(current: nil, count: 1) == "1 Ad Break")
    #expect(TranscriptAdBreakBar.title(current: 1, count: 4) == "Break 2 of 4")
  }

  @Test("search's matches take the bottom bar; breaks have it otherwise, marking included")
  func bottomBar() {
    #expect(TranscriptBottomBar.content(hasMatches: true, breakCount: 3) == .search)
    #expect(TranscriptBottomBar.content(hasMatches: false, breakCount: 3) == .adBreaks)
    #expect(TranscriptBottomBar.content(hasMatches: false, breakCount: 0) == .none)
  }
}

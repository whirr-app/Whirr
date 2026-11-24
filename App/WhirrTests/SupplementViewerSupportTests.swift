import Foundation
import TestSupport
import Testing

@testable import Whirr

/// The viewer's page memory and its link handling, kept apart from PDFKit. The viewer itself is
/// checked on device.
@MainActor
@Suite struct SupplementViewerSupportTests {

  @Test func theViewerOpensAtTheRememberedPageWithinTheDocument() {
    #expect(SupplementPageMemory.initialPageIndex(lastViewedPage: nil, pageCount: 48) == 0)
    #expect(SupplementPageMemory.initialPageIndex(lastViewedPage: 11, pageCount: 48) == 11)
    // A file replaced by a shorter one on the server must not open past its end.
    #expect(SupplementPageMemory.initialPageIndex(lastViewedPage: 60, pageCount: 48) == 47)
    #expect(SupplementPageMemory.initialPageIndex(lastViewedPage: -3, pageCount: 48) == 0)
    #expect(SupplementPageMemory.initialPageIndex(lastViewedPage: 5, pageCount: 0) == 0)
  }

  @Test func theIndicatorIsOneBased() {
    #expect(SupplementPageMemory.indicator(pageIndex: 11, pageCount: 48) == "12 of 48")
    #expect(SupplementPageMemory.indicator(pageIndex: 0, pageCount: 1) == "1 of 1")
    #expect(SupplementPageMemory.indicator(pageIndex: 0, pageCount: 0) == "")
  }

  @Test func scrollingWritesOnlyThePageTheReaderSettlesOn() async {
    var written: [Int] = []
    let writer = SupplementPageWriter(initialPage: 2, delay: .seconds(60)) { written.append($0) }

    writer.noteVisible(pageIndex: 3)
    writer.noteVisible(pageIndex: 4)
    writer.noteVisible(pageIndex: 5)
    await writer.flush()
    #expect(written == [5])

    // Returning to the page already stored leaves nothing pending.
    writer.noteVisible(pageIndex: 6)
    writer.noteVisible(pageIndex: 5)
    await writer.flush()
    #expect(written == [5])
  }

  @Test func theSettledPageIsWrittenWithoutAFlush() async throws {
    var written: [Int] = []
    let writer = SupplementPageWriter(initialPage: nil, delay: .milliseconds(10)) {
      written.append($0)
    }

    writer.noteVisible(pageIndex: 7)
    await waitUntil("the settled page is written") { written.isEmpty == false }
    #expect(written == [7])
  }

  @Test func closingTheViewerWritesThePendingPageAtOnce() async {
    var written: [Int] = []
    let writer = SupplementPageWriter(initialPage: nil, delay: .seconds(60)) { written.append($0) }

    writer.noteVisible(pageIndex: 9)
    await writer.flush()
    #expect(written == [9])
    await writer.flush()
    #expect(written == [9], "nothing pending, nothing written")
  }

  @Test func webAndMailLinksAreConfirmedWithTheirHostShown() throws {
    let url = try #require(URL(string: "https://maps.example.com/realm?id=1"))
    #expect(
      SupplementLinkAction.action(for: url)
        == .confirm(url: url, displayedTarget: "maps.example.com"))
    let mail = try #require(URL(string: "mailto:author@example.com"))
    if case .confirm = SupplementLinkAction.action(for: mail) {
    } else {
      Issue.record("a mailto link is confirmed, not refused")
    }
  }

  /// A PDF is untrusted server content: code, the container, and other apps' schemes never open.
  @Test func linksThatCouldRunCodeOrReachTheDeviceAreRefused() throws {
    for href in [
      "javascript:alert(1)", "data:text/html,hi", "file:///private/var/mobile/x.pdf",
      "otherapp://open", "shortcuts://run-shortcut",
    ] {
      let url = try #require(URL(string: href))
      #expect(SupplementLinkAction.action(for: url) == .refuse, "\(href)")
    }
  }
}

import Foundation
import Testing

@testable import ReaderCore

@Suite struct TOCEntryTests {

  @Test func negativeDepthIsClampedToTheRoot() {
    #expect(TOCEntry(title: "Root", href: "Text/root.xhtml", depth: -1).depth == 0)
  }

  @Test func startProgressionDefaultsToAbsentAndIsClampedToTheUnitInterval() {
    #expect(TOCEntry(title: "Root", href: "Text/root.xhtml", depth: 0).startProgression == nil)
    #expect(
      TOCEntry(title: "Root", href: "Text/root.xhtml", depth: 0, startProgression: -0.5)
        .startProgression == 0)
    #expect(
      TOCEntry(title: "Root", href: "Text/root.xhtml", depth: 0, startProgression: 1.5)
        .startProgression == 1)
  }

  @Test func oversizedTitleIsTruncatedToTheBound() {
    let title = String(repeating: "t", count: TOCEntry.maximumTitleBytes + 500)

    let entry = TOCEntry(title: title, href: "Text/root.xhtml", depth: 0)

    #expect(entry.title.utf8.count <= TOCEntry.maximumTitleBytes)
  }

  @Test func truncationNeverSplitsAMultiByteCharacter() {
    // A title of 3-byte characters whose bound falls mid-character: the result must still decode.
    let title = String(repeating: "\u{4E16}", count: TOCEntry.maximumTitleBytes)

    let entry = TOCEntry(title: title, href: nil, depth: 0)

    #expect(entry.title.utf8.count <= TOCEntry.maximumTitleBytes)
    #expect(entry.title.allSatisfy { $0 == "\u{4E16}" })
  }
}

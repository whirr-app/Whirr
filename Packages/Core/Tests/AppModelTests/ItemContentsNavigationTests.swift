import Foundation
import ReaderCore
import Testing

@testable import AppModel

@Suite struct ItemContentsNavigationTests {
  @Test("an entry with an href opens at that resource, carrying its whole-book fraction")
  func anEntryWithAnHrefOpensAtThatResource() {
    let entry = TOCEntry(
      title: "Chapter 2", href: "Text/ch2.xhtml#start", depth: 0, startProgression: 0.4)

    guard case .position(let position) = ItemContentsNavigation.target(for: entry) else {
      Issue.record("expected a position target")
      return
    }
    #expect(position.href == "Text/ch2.xhtml#start")
    #expect(position.totalProgression == 0.4)
    #expect(position.progression == 0)
  }

  /// Readium resolves an href against the publication, so an entry whose resource the positions
  /// list never resolved is still navigable, it just carries no fraction.
  @Test("an entry with an href but no resolved fraction is still navigable")
  func anEntryWithoutAFractionIsStillNavigable() {
    let entry = TOCEntry(title: "Notes", href: "Text/notes.xhtml", depth: 1)

    guard case .position(let position) = ItemContentsNavigation.target(for: entry) else {
      Issue.record("expected a position target")
      return
    }
    #expect(position.href == "Text/notes.xhtml")
    #expect(position.totalProgression == 0)
  }

  @Test("an entry with only a fraction falls back to opening at that fraction")
  func anEntryWithOnlyAFractionOpensAtThatFraction() {
    let entry = TOCEntry(title: "Chapter 2", depth: 0, startProgression: 0.4)

    #expect(ItemContentsNavigation.target(for: entry) == .totalProgression(0.4))
  }

  /// Nothing to aim at is not a reason to refuse to open the book: the caller falls back to the
  /// reader's own saved position.
  @Test("an entry with neither an href nor a fraction has no target")
  func anEntryWithNeitherHasNoTarget() {
    #expect(ItemContentsNavigation.target(for: TOCEntry(title: "Untitled", depth: 0)) == nil)
  }

  @Test("an empty href is treated as absent rather than navigated to")
  func anEmptyHrefIsTreatedAsAbsent() {
    let entry = TOCEntry(title: "Part", href: "", depth: 0, startProgression: 0.2)

    #expect(ItemContentsNavigation.target(for: entry) == .totalProgression(0.2))
  }

  @Test("tapping the entry being read has no target, so the reader opens where reading left off")
  func theCurrentEntryOpensAtTheSavedPosition() {
    let entry = TOCEntry(
      title: "Chapter 2", href: "Text/ch2.xhtml", depth: 0, startProgression: 0.4)
    let row = ItemContentsRow(id: 1, entry: entry, isCurrent: true, isCompleted: false)

    #expect(ItemContentsNavigation.target(for: row) == nil)
  }

  @Test("tapping any other entry opens at that entry")
  func anEntryThatIsNotCurrentOpensAtItself() {
    let entry = TOCEntry(
      title: "Chapter 3", href: "Text/ch3.xhtml", depth: 0, startProgression: 0.6)
    let row = ItemContentsRow(id: 2, entry: entry, isCurrent: false, isCompleted: false)

    guard case .position(let position) = ItemContentsNavigation.target(for: row) else {
      Issue.record("expected a position target")
      return
    }
    #expect(position.href == "Text/ch3.xhtml")
  }

  /// A completed entry is a reread, not a resume: it is behind the reading position, so its own
  /// start is the only sensible destination.
  @Test("a completed entry still opens at its own start")
  func aCompletedEntryOpensAtItsOwnStart() {
    let entry = TOCEntry(title: "Chapter 1", depth: 0, startProgression: 0.1)
    let row = ItemContentsRow(id: 0, entry: entry, isCurrent: false, isCompleted: true)

    #expect(ItemContentsNavigation.target(for: row) == .totalProgression(0.1))
  }
}

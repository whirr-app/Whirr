import Foundation
import ReaderCore
import Testing

@testable import AppModel

@Suite struct ItemContentsPresentationTests {
  private static let entries = [
    TOCEntry(title: "Cover", href: "cover.xhtml", depth: 0, startProgression: 0),
    TOCEntry(title: "Chapter 1", href: "ch1.xhtml", depth: 0, startProgression: 0.1),
    TOCEntry(title: "Chapter 2", href: "ch2.xhtml", depth: 0, startProgression: 0.4),
    TOCEntry(title: "Chapter 3", href: "ch3.xhtml", depth: 0, startProgression: 0.7),
  ]

  @Test("the entry containing the reading position is current and every earlier one is read")
  func readingPositionMarksCurrentAndEarlierEntries() {
    let rows = ItemContentsPresentation.rows(
      entries: Self.entries, progress: 0.5, isFinished: false)

    #expect(rows.map(\.isCurrent) == [false, false, true, false])
    #expect(rows.map(\.isCompleted) == [true, true, false, false])
  }

  @Test("a position exactly on an entry's start belongs to that entry, not the one before")
  func aPositionOnABoundaryBelongsToTheEntryItStarts() {
    let rows = ItemContentsPresentation.rows(
      entries: Self.entries, progress: 0.4, isFinished: false)

    #expect(rows.map(\.isCurrent) == [false, false, true, false])
  }

  /// The `nil`-progress degradation the Chapters tab already documents: with nothing read, no row
  /// invents a state.
  @Test("no reading progress leaves every entry unmarked")
  func noReadingProgressLeavesEveryEntryUnmarked() {
    let rows = ItemContentsPresentation.rows(
      entries: Self.entries, progress: nil, isFinished: false)

    #expect(rows.allSatisfy { $0.isCurrent == false && $0.isCompleted == false })
  }

  /// Mirrors `ChapterSelectorPresentation`: finished is a property of the item, so it completes
  /// every entry regardless of where the reading position currently sits.
  @Test("a finished book completes every entry even while it is being reread")
  func aFinishedBookCompletesEveryEntry() {
    let rows = ItemContentsPresentation.rows(
      entries: Self.entries, progress: 0.2, isFinished: true)

    #expect(rows.allSatisfy { $0.isCompleted })
    #expect(rows.map(\.isCurrent) == [false, true, false, false])
  }

  /// A navigation entry whose resource the positions list could not resolve must stay listed and
  /// simply never claim a read state. It must not swallow the entries around it either.
  @Test("an entry without a resolved progression is listed but never current")
  func anUnresolvedEntryIsListedButNeverCurrent() {
    let entries = [
      TOCEntry(title: "Chapter 1", href: "ch1.xhtml", depth: 0, startProgression: 0.1),
      TOCEntry(title: "Notes", href: nil, depth: 1, startProgression: nil),
      TOCEntry(title: "Chapter 2", href: "ch2.xhtml", depth: 0, startProgression: 0.6),
    ]

    let rows = ItemContentsPresentation.rows(entries: entries, progress: 0.7, isFinished: false)

    #expect(rows.map(\.isCurrent) == [false, false, true])
    #expect(rows.map(\.isCompleted) == [true, true, false])
  }

  @Test("a position before the first resolved entry marks nothing read")
  func aPositionBeforeTheFirstEntryMarksNothingRead() {
    let entries = [
      TOCEntry(title: "Chapter 1", href: "ch1.xhtml", depth: 0, startProgression: 0.3),
      TOCEntry(title: "Chapter 2", href: "ch2.xhtml", depth: 0, startProgression: 0.6),
    ]

    let rows = ItemContentsPresentation.rows(entries: entries, progress: 0.1, isFinished: false)

    #expect(rows.allSatisfy { $0.isCurrent == false && $0.isCompleted == false })
  }

  @Test("rows carry their entry through unchanged so selection still has an href")
  func rowsCarryTheirEntryThrough() {
    let rows = ItemContentsPresentation.rows(
      entries: Self.entries, progress: nil, isFinished: false)

    #expect(rows.map(\.entry) == Self.entries)
    #expect(rows.map(\.id) == [0, 1, 2, 3])
  }
}

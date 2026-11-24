import AppModel
import Foundation
import Persistence
import SwiftUI
import Testing

@testable import Whirr

@Suite("Library collection snapshot")
struct LibraryBrowseCollectionSnapshotTests {

  @Test("the controls row comes first and empty letters are omitted")
  func controlsFirstAndEmptyLettersOmitted() {
    let items = [Self.item("a1", "Alpha"), Self.item("c1", "Charlie")]
    let snapshot = Self.titles(items)

    #expect(snapshot.sections.first?.id == .controls)
    #expect(snapshot.sections.first?.items == [.controls])
    #expect(
      snapshot.sections.map(\.id) == [
        .controls, .letter(.titles, "A"), .letter(.titles, "C"),
      ])
    #expect(snapshot.sections.allSatisfy { $0.items.isEmpty == false })
  }

  @Test("every letter header answers to the jump menu's target ID")
  func letterTargetsMatchTheJumpMenu() throws {
    let snapshot = Self.titles([Self.item("b1", "Bravo")])
    let letter = try #require(snapshot.sections.last?.id)

    #expect(
      LibraryBrowseCollectionSnapshot.targetID(for: letter)
        == LibraryBrowseLayoutPresentation.sectionTargetID(for: "B", in: .titles, hasItems: true))
    #expect(snapshot.section(forTargetID: "library-section-titles-B") == letter)
    #expect(LibraryBrowseCollectionSnapshot.targetID(for: .controls) == nil)
  }

  // `serverItemId` is unique per library, not across them, and the browse read spans libraries.
  // A diffable snapshot throws on a repeated identifier where `ForEach` only logged.
  @Test("a repeated title identifier is dropped and the first occurrence kept")
  func duplicateTitlesKeepTheFirst() {
    let first = Self.item("dup", "Delta", author: "First")
    let second = Self.item("dup", "Delta", author: "Second")
    let snapshot = Self.titles([first, second])

    #expect(snapshot.itemIdentifiers.filter { $0 == .title("dup") }.count == 1)
    #expect(snapshot.titles["dup"]?.author == "First")
    #expect(snapshot.prefetchIndices[.title("dup")] == 0)
  }

  @Test("a repeated entity is dropped, first occurrence kept, even across letters")
  func duplicateEntitiesKeepTheFirst() {
    let a = Self.group(.series, id: "s1", name: "Aardvark", items: [Self.item("x", "X")])
    let again = Self.group(.series, id: "s1", name: "Zebra", items: [Self.item("y", "Y")])
    let snapshot = LibraryBrowseCollectionSnapshot.entities(
      mode: .series,
      rows: .rows,
      hasMore: false,
      values: [a, again],
      sections: [
        .init(id: "A", items: [a]),
        .init(id: "Z", items: [again]),
      ])

    #expect(snapshot.sections.map(\.id) == [.controls, .letter(.series, "A")])
    #expect(snapshot.groups[a.id]?.name == "Aardvark")
  }

  @Test("entities are keyed by the group's kind-qualified identity")
  func entitiesKeyedByGroupID() {
    let author = Self.group(.author, id: "e1", name: "Asimov", items: [])
    let snapshot = LibraryBrowseCollectionSnapshot.entities(
      mode: .authors, rows: .rows, hasMore: false, values: [author],
      sections: [.init(id: "A", items: [author])])

    #expect(snapshot.itemIdentifiers.contains(.author(author.id)))
    #expect(author.id == "author#e1")
  }

  @Test("load more appears only while another page exists, even with no letters")
  func loadMoreOnlyWhenMore() {
    let none = LibraryBrowseCollectionSnapshot.entities(
      mode: .series, rows: .rows, hasMore: true, values: [], sections: [])
    let done = LibraryBrowseCollectionSnapshot.entities(
      mode: .series, rows: .rows, hasMore: false, values: [], sections: [])

    #expect(none.sections.map(\.id) == [.controls, .loadMore])
    #expect(done.sections.map(\.id) == [.controls])
  }

  @Test("non-row presentations show controls with the state row or nothing")
  func nonRowPresentations() {
    let items = [Self.item("a1", "Alpha")]
    let sections = LibraryBrowsePresentation.indexedSections(for: items)

    let filtered = LibraryBrowseCollectionSnapshot.titles(
      rows: .filteredEmpty, banner: "Offline", values: items, sections: sections)
    let queried = LibraryBrowseCollectionSnapshot.titles(
      rows: .queryEmpty(query: "zz", offersClearFilters: false), banner: nil, values: items,
      sections: sections)
    let overlay = LibraryBrowseCollectionSnapshot.titles(
      rows: .none, banner: nil, values: items, sections: sections)

    #expect(filtered.sections.map(\.id) == [.controls, .state])
    #expect(filtered.banner == nil)
    #expect(queried.sections.map(\.id) == [.controls, .state])
    #expect(overlay.sections.map(\.id) == [.controls])
  }

  @Test("the stale-offline banner sits between the controls and the first letter")
  func bannerPlacement() {
    let snapshot = LibraryBrowseCollectionSnapshot.titles(
      rows: .rows, banner: "Showing saved titles", values: [Self.item("a1", "Alpha")],
      sections: LibraryBrowsePresentation.indexedSections(for: [Self.item("a1", "Alpha")]))
    let empty = LibraryBrowseCollectionSnapshot.titles(
      rows: .rows, banner: "", values: [], sections: [])

    #expect(snapshot.sections.map(\.id) == [.controls, .banner, .letter(.titles, "A")])
    #expect(snapshot.banner == "Showing saved titles")
    #expect(empty.sections.map(\.id) == [.controls])
  }

  @Test("titles prefetch in source order")
  func titlePrefetchOrdering() {
    let items = [Self.item("b", "Bravo"), Self.item("a", "Alpha")]
    let snapshot = Self.titles(items)

    #expect(snapshot.prefetchOrder == ["b", "a"])
    #expect(snapshot.prefetchIndices[.title("b")] == 0)
    #expect(snapshot.prefetchIndices[.title("a")] == 1)
  }

  @Test("series prefetch by cover item, first occurrence, skipping coverless series")
  func seriesPrefetchOrdering() {
    let coverless = Self.group(.series, id: "s0", name: "Alpha", items: [])
    let first = Self.group(.series, id: "s1", name: "Bravo", items: [Self.item("c1", "One")])
    let shared = Self.group(.series, id: "s2", name: "Charlie", items: [Self.item("c1", "One")])
    let values = [coverless, first, shared]
    let snapshot = LibraryBrowseCollectionSnapshot.entities(
      mode: .series, rows: .rows, hasMore: false, values: values,
      sections: LibraryBrowsePresentation.indexedSections(for: values, title: \.name))

    #expect(snapshot.prefetchOrder == ["c1", "c1"])
    #expect(snapshot.prefetchIndices[.series(first.id)] == 0)
    #expect(snapshot.prefetchIndices[.series(shared.id)] == 0)
    #expect(snapshot.prefetchIndices[.series(coverless.id)] == nil)
  }

  @Test("authors do not prefetch")
  func authorsDoNotPrefetch() {
    let author = Self.group(.author, id: "e1", name: "Asimov", items: [Self.item("i", "I")])
    let snapshot = LibraryBrowseCollectionSnapshot.entities(
      mode: .authors, rows: .rows, hasMore: false, values: [author],
      sections: [.init(id: "A", items: [author])])

    #expect(snapshot.prefetchOrder.isEmpty)
    #expect(snapshot.prefetchIndices.isEmpty)
  }

  @Test("the same letter in two modes is two identities")
  func lettersAreModeQualified() {
    let title = Self.titles([Self.item("a1", "Alpha")])
    let author = Self.group(.author, id: "e1", name: "Asimov", items: [])
    let authors = LibraryBrowseCollectionSnapshot.entities(
      mode: .authors, rows: .rows, hasMore: false, values: [author],
      sections: [.init(id: "A", items: [author])])

    #expect(title.sections.last?.id != authors.sections.last?.id)
  }

  private static func titles(_ items: [ItemSummary]) -> LibraryBrowseCollectionSnapshot {
    .titles(
      rows: .rows, banner: nil, values: items,
      sections: LibraryBrowsePresentation.indexedSections(for: items))
  }

  private static func item(_ id: String, _ title: String, author: String? = nil) -> ItemSummary {
    ItemSummary.fixture(
      serverItemId: id, mediaKind: "book", title: title, author: author,
      durationSeconds: nil, category: .audiobook)
  }

  private static func group(
    _ kind: SearchResultKind, id: String, name: String, items: [ItemSummary]
  ) -> LibraryEntityGroup {
    LibraryEntityGroup(
      entity: AuthorSeriesEntity(kind: kind, entityID: id, name: name, libraryID: "lib"),
      items: items,
      isFiltered: false)
  }
}

@Suite("Library collection metrics")
struct LibraryBrowseCollectionMetricsTests {

  @Test("the available width removes the safe area and the page inset once")
  func availableWidth() {
    #expect(
      LibraryBrowseCollectionMetrics.availableWidth(
        containerWidth: 1376, safeAreaLeading: 0, safeAreaTrailing: 0) == 1344)
    #expect(
      LibraryBrowseCollectionMetrics.availableWidth(
        containerWidth: 1032, safeAreaLeading: 0, safeAreaTrailing: 0) == 1000)
    #expect(
      LibraryBrowseCollectionMetrics.availableWidth(
        containerWidth: 420, safeAreaLeading: 10, safeAreaTrailing: 10) == 368)
  }

  @Test("a first layout pass without a width keeps the two-column fallback")
  func zeroWidthIsNil() {
    #expect(
      LibraryBrowseCollectionMetrics.availableWidth(
        containerWidth: 0, safeAreaLeading: 0, safeAreaTrailing: 0) == nil)
    #expect(
      LibraryBrowseCollectionMetrics.availableWidth(
        containerWidth: 20, safeAreaLeading: 0, safeAreaTrailing: 0) == nil)
    let fallback = LibraryBrowseCollectionMetrics.resolve(
      for: .titles, availableWidth: nil, isAccessibilitySize: false)
    #expect(fallback.columns == 2)
    #expect(fallback.tileWidth == LibraryBrowseLayoutPresentation.regularCoverMinimumWidth)
  }

  @Test("13-inch widths resolve the SwiftUI grid's columns and tiles")
  func thirteenInchWidths() {
    let landscape = LibraryBrowseCollectionMetrics.resolve(
      for: .titles, availableWidth: 1344, isAccessibilitySize: false)
    let portrait = LibraryBrowseCollectionMetrics.resolve(
      for: .titles, availableWidth: 1000, isAccessibilitySize: false)

    #expect(landscape.columns == 8)
    #expect(landscape.tileWidth == 157)
    #expect(portrait.columns == 6)
    #expect(portrait.tileWidth == 156)
    #expect(landscape.rowWidth <= 1344)
    #expect(portrait.rowWidth <= 1000)
  }

  @Test("author cards keep their 320-point outer minimum")
  func authorMinimum() {
    let authors = LibraryBrowseCollectionMetrics.resolve(
      for: .authors, availableWidth: 1000, isAccessibilitySize: false)

    #expect(authors.columns == 3)
    #expect(authors.tileWidth >= LibraryBrowseLayoutPresentation.authorCardOuterMinimumWidth)
  }

  @Test("accessibility sizes widen the minimum and so reduce the columns")
  func accessibilitySizes() {
    let metrics = LibraryBrowseCollectionMetrics.resolve(
      for: .titles, availableWidth: 1000, isAccessibilitySize: true)

    #expect(metrics.columns == 4)
    #expect(metrics.tileWidth >= LibraryBrowseLayoutPresentation.accessibilityCoverMinimumWidth)
  }
}

@Suite("Library collection scroll phases")
struct LibraryBrowseScrollPhaseMappingTests {

  @Test("each UIKit scroll callback stands for the phase the SwiftUI grid reported")
  func callbacksMapToPhases() {
    #expect(LibraryBrowseScrollEvent.willBeginDragging.phase == .interacting)
    #expect(LibraryBrowseScrollEvent.didEndDragging(willDecelerate: false).phase == .idle)
    #expect(LibraryBrowseScrollEvent.willBeginDecelerating.phase == .decelerating)
    #expect(LibraryBrowseScrollEvent.didEndDecelerating.phase == .idle)
    #expect(LibraryBrowseScrollEvent.beganAnimatedScroll.phase == .animating)
    #expect(LibraryBrowseScrollEvent.didEndScrollingAnimation.phase == .idle)
    #expect(LibraryBrowseScrollEvent.didScrollToTop.phase == .idle)
  }

  // Answering `.idle` between the drag and the deceleration would lift presentation deferral for
  // one frame in the middle of every fling.
  @Test("a drag that hands over to deceleration reports nothing")
  func flingDoesNotIdle() {
    #expect(LibraryBrowseScrollEvent.didEndDragging(willDecelerate: true).phase == nil)
  }
}

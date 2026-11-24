import Foundation
import Testing

@testable import DesignSystem

struct FlowRowLayoutTests {
  @Test("items that fit share one row")
  func itemsThatFitShareOneRow() {
    let rows = FlowLayoutSolver.rows(itemWidths: [40, 60, 50], containerWidth: 200, spacing: 0)

    #expect(rows.map(\.indices) == [[0, 1, 2]])
    #expect(rows.map(\.width) == [150])
  }

  @Test("spacing counts between items, not around them")
  func spacingCountsBetweenItemsOnly() {
    let rows = FlowLayoutSolver.rows(itemWidths: [40, 60, 50], containerWidth: 200, spacing: 10)

    #expect(rows.map(\.indices) == [[0, 1, 2]])
    #expect(rows.map(\.width) == [170])
  }

  @Test("an exact fit does not wrap")
  func exactFitDoesNotWrap() {
    let rows = FlowLayoutSolver.rows(itemWidths: [100, 100], containerWidth: 200, spacing: 0)

    #expect(rows.map(\.indices) == [[0, 1]])
  }

  @Test("the first item that would overflow starts the next row")
  func overflowingItemStartsNextRow() {
    let rows = FlowLayoutSolver.rows(itemWidths: [120, 100, 40], containerWidth: 200, spacing: 0)

    #expect(rows.map(\.indices) == [[0], [1, 2]])
    #expect(rows.map(\.width) == [120, 140])
  }

  @Test("spacing can be what pushes an item onto the next row")
  func spacingCanForceTheWrap() {
    let rows = FlowLayoutSolver.rows(itemWidths: [100, 100], containerWidth: 200, spacing: 8)

    #expect(rows.map(\.indices) == [[0], [1]])
  }

  @Test("an item wider than the container gets a row to itself rather than an empty one above it")
  func oversizedItemTakesItsOwnRow() {
    let rows = FlowLayoutSolver.rows(itemWidths: [300, 40], containerWidth: 200, spacing: 0)

    #expect(rows.map(\.indices) == [[0], [1]])
    #expect(rows.map(\.width) == [300, 40])
  }

  @Test("no items means no rows")
  func noItemsMeansNoRows() {
    #expect(FlowLayoutSolver.rows(itemWidths: [], containerWidth: 200, spacing: 8).isEmpty)
  }

  @Test("a container of unknown width keeps everything on one row")
  func unknownContainerWidthKeepsOneRow() {
    let rows = FlowLayoutSolver.rows(itemWidths: [300, 400], containerWidth: CGFloat.infinity, spacing: 4)

    #expect(rows.map(\.indices) == [[0, 1]])
  }
}

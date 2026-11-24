import SwiftUI

/// Greedy line breaking for a wrapping row of views: which item indices share each row, and how
/// wide that row comes out. Split out from the `Layout` so the arithmetic (which decides whether
/// a credit reads as one line or three) is exercised on the host.
public enum FlowLayoutSolver {
  public struct Row: Equatable, Sendable {
    public let indices: [Int]
    /// The row's laid-out width, spacing between its items included.
    public let width: CGFloat

    public init(indices: [Int], width: CGFloat) {
      self.indices = indices
      self.width = width
    }
  }

  public static func rows(
    itemWidths: [CGFloat], containerWidth: CGFloat, spacing: CGFloat
  ) -> [Row] {
    var rows: [Row] = []
    var current: [Int] = []
    var currentWidth: CGFloat = 0

    for (index, width) in itemWidths.enumerated() {
      let advance = current.isEmpty ? width : currentWidth + spacing + width
      // An item wider than the container still has to go somewhere; it gets its own row and
      // overflows, rather than pushing an empty row ahead of itself.
      if current.isEmpty == false, advance > containerWidth {
        rows.append(Row(indices: current, width: currentWidth))
        current = [index]
        currentWidth = width
      } else {
        current.append(index)
        currentWidth = advance
      }
    }
    if current.isEmpty == false {
      rows.append(Row(indices: current, width: currentWidth))
    }
    return rows
  }
}

/// A wrapping row of views, for a credit line where a two-narrator book must break into two lines
/// rather than being squeezed or clipped. Each row is set to `alignment` (centred under a centred
/// title, leading in a leading column).
///
/// Preferred over a single `Text` of link runs for the touch target: each subview is a real
/// control with its own padding.
public struct FlowRowLayout: Layout {
  public enum RowAlignment: Sendable {
    case leading
    case center
  }

  private let alignment: RowAlignment
  private let spacing: CGFloat
  private let rowSpacing: CGFloat

  public init(alignment: RowAlignment = .center, spacing: CGFloat = 0, rowSpacing: CGFloat = 0) {
    self.alignment = alignment
    self.spacing = spacing
    self.rowSpacing = rowSpacing
  }

  public func sizeThatFits(
    proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
  ) -> CGSize {
    let sizes = sizes(of: subviews, within: proposal.width)
    let rows = FlowLayoutSolver.rows(
      itemWidths: sizes.map(\.width),
      containerWidth: proposal.width ?? .infinity,
      spacing: spacing)
    guard rows.isEmpty == false else { return .zero }

    let heights = rows.map { row in row.indices.map { sizes[$0].height }.max() ?? 0 }
    let widest = rows.map(\.width).max() ?? 0
    return CGSize(
      // Never wider than what was offered. The solver gives an item too wide for the container a
      // row of its own and lets it overflow, and reporting that overflow as the layout's own
      // width would let one credit decide the width of the whole column.
      width: proposal.width.map { min(widest, $0) } ?? widest,
      height: heights.reduce(0, +) + rowSpacing * CGFloat(rows.count - 1))
  }

  public func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void
  ) {
    let sizes = sizes(of: subviews, within: proposal.width ?? bounds.width)
    let rows = FlowLayoutSolver.rows(
      itemWidths: sizes.map(\.width),
      containerWidth: proposal.width ?? bounds.width,
      spacing: spacing)

    var y = bounds.minY
    for row in rows {
      let rowHeight = row.indices.map { sizes[$0].height }.max() ?? 0
      var x =
        switch alignment {
        case .leading: bounds.minX
        case .center: bounds.minX + (bounds.width - row.width) / 2
        }
      for index in row.indices {
        let size = sizes[index]
        subviews[index].place(
          at: CGPoint(x: x, y: y + (rowHeight - size.height) / 2),
          proposal: ProposedViewSize(size))
        x += size.width + spacing
      }
      y += rowHeight + rowSpacing
    }
  }

  /// What each subview is measured and placed at.
  ///
  /// `.unspecified` gives a `Text`'s one-line width, which is right for deciding where rows break
  /// and wrong for an item that cannot fit a row at all: at the largest accessibility type size a
  /// single series credit runs 681 pt on a 402 pt screen, `sizeThatFits` reports that as the
  /// layout's width, and the detail column grows to match and clips at both edges.
  ///
  /// Only items that overrun are re-measured; the rest keep their natural size, so row breaking is
  /// unchanged for credit lines that were never in trouble.
  private func sizes(of subviews: Subviews, within width: CGFloat?) -> [CGSize] {
    guard let width, width.isFinite, width > 0 else {
      return subviews.map { $0.sizeThatFits(.unspecified) }
    }
    return subviews.map { subview in
      let natural = subview.sizeThatFits(.unspecified)
      guard natural.width > width else { return natural }
      return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }
  }
}

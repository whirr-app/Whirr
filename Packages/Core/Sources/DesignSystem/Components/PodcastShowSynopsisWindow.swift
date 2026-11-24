import SwiftUI

/// Which part of a show synopsis a window shows. The synopsis is laid out once in full and cut
/// into its first three lines (the head, in the show header) and the rest (the tail, its own list
/// row).
///
/// The split exists for `List`: a row that changes height in place snaps while its content
/// animates inside it, but a row inserted or removed animates natively, with the rows below
/// sliding. So the head never changes size, and expanding inserts the tail.
nonisolated enum PodcastShowSynopsisWindow: Equatable {
  case head
  case tail

  /// `collapsedHeight` is the synopsis at three lines, `fullHeight` the whole of it, both at the
  /// same width.
  func height(collapsedHeight: CGFloat, fullHeight: CGFloat) -> CGFloat {
    switch self {
    case .head: min(collapsedHeight, fullHeight)
    case .tail: max(fullHeight - collapsedHeight, 0)
    }
  }

  /// How far the full synopsis is moved up inside the window.
  func offset(collapsedHeight: CGFloat, fullHeight: CGFloat) -> CGFloat {
    switch self {
    case .head: 0
    case .tail: -min(collapsedHeight, fullHeight)
    }
  }

  /// Half a point of slack absorbs rounding between the two layouts.
  static func isTruncated(collapsedHeight: CGFloat, fullHeight: CGFloat) -> Bool {
    fullHeight > collapsedHeight + 0.5
  }
}

/// Sizes itself to one window of the synopsis, measured synchronously from its two subviews (the
/// three-line copy, then the full copy), so the window is right on the first frame.
struct PodcastShowSynopsisWindowLayout: Layout {
  let window: PodcastShowSynopsisWindow

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard subviews.count == 2 else { return .zero }
    let width = proposal.width ?? subviews[1].sizeThatFits(.unspecified).width
    let heights = Self.heights(of: subviews, width: width)
    return CGSize(
      width: width, height: window.height(collapsedHeight: heights.collapsed, fullHeight: heights.full))
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    guard subviews.count == 2 else { return }
    let heights = Self.heights(of: subviews, width: bounds.width)
    let proposal = ProposedViewSize(width: bounds.width, height: nil)
    subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
    let offset = window.offset(collapsedHeight: heights.collapsed, fullHeight: heights.full)
    subviews[1].place(
      at: CGPoint(x: bounds.minX, y: bounds.minY + offset), anchor: .topLeading, proposal: proposal)
  }

  private static func heights(of subviews: Subviews, width: CGFloat) -> (
    collapsed: CGFloat, full: CGFloat
  ) {
    let proposal = ProposedViewSize(width: width, height: nil)
    return (subviews[0].sizeThatFits(proposal).height, subviews[1].sizeThatFits(proposal).height)
  }
}

/// One window of the synopsis, clipped. Reports the measured heights so the head can tell whether
/// anything was cut off.
struct PodcastShowSynopsisWindowView: View {
  let synopsis: String
  let window: PodcastShowSynopsisWindow
  var onMeasure: ((_ collapsedHeight: CGFloat, _ fullHeight: CGFloat) -> Void)?

  @State private var collapsedHeight: CGFloat = 0
  @State private var fullHeight: CGFloat = 0

  var body: some View {
    PodcastShowSynopsisWindowLayout(window: window) {
      text(lineLimit: PodcastShowSynopsisStyle.collapsedLineLimit)
        .hidden()
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          collapsedHeight = $0
          onMeasure?($0, fullHeight)
        }
      text(lineLimit: nil)
        .onGeometryChange(for: CGFloat.self) {
          $0.size.height
        } action: {
          fullHeight = $0
          onMeasure?(collapsedHeight, $0)
        }
    }
    .clipped()
  }

  private func text(lineLimit: Int?) -> some View {
    Text(synopsis)
      .font(WhirrTypeToken.body.font)
      .foregroundStyle(WashInk.secondary)
      .lineLimit(lineLimit)
      .fixedSize(horizontal: false, vertical: true)
  }
}

nonisolated enum PodcastShowSynopsisStyle {
  static let collapsedLineLimit = 3
}

/// The rest of a show's synopsis, past the three lines the header shows. A screen inserts it as
/// its own row, directly below the header, while the synopsis is expanded. Hidden from
/// accessibility: the header's synopsis element already voices the whole blurb.
public struct PodcastShowSynopsisContinuationView: View {
  public let synopsis: String

  public init(synopsis: String) {
    self.synopsis = synopsis
  }

  public var body: some View {
    PodcastShowSynopsisWindowView(synopsis: synopsis, window: .tail)
      .frame(maxWidth: .infinity, alignment: .leading)
      // The full text is moved up behind the header's three lines, so its first baseline sits
      // above this view. A `List` row moves its content down to bring that baseline inside the
      // row, which opened a gap above the fourth line.
      .alignmentGuide(.firstTextBaseline) { $0[.top] }
      .accessibilityHidden(true)
  }
}

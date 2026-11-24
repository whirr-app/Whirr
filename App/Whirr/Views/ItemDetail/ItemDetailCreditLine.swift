import AppModel
import DesignSystem
import SwiftUI

/// One credit line: names, each its own button opening its semantic collection. Real controls in
/// a wrapping row, not link runs in one `Text` (tappable only on glyphs, leaving adjacent credits
/// a couple of points apart).
///
/// Nothing is accent-tinted: the block sits above an accent-filled play button and would read as
/// one gold wash. Names are heavier and a step brighter than their surroundings, which also stops
/// the lead-in and commas looking tappable. The caller passes the rung (not full `.primary`, which
/// leaves the hero no entry point); `WhirrMetadataProminence` sets levels for this screen and the
/// player, so weight alone says "control".
///
/// A long credit is counted, not listed (eight names push the blurb and play button off the first
/// screen). `ItemMetadataLinkPresentation` owns the cut; this view owns whether it is open, per
/// line. While a credit is unresolved the placeholder is drawn invisibly, holding the row's height
/// so the block doesn't reflow when metadata lands (`ItemDetailMetadataLayout`).
struct ItemDetailCreditLine: View {
  let links: [ItemMetadataLink]
  let placeholder: String?
  let prominence: WhirrMetadataProminence
  let alignment: HeroColumnAlignment
  let leadIn: String?
  let onOpenMetadata: (ItemMetadataLink) -> Void
  let isBreadcrumb: Bool

  init(
    links: [ItemMetadataLink], placeholder: String?,
    prominence: WhirrMetadataProminence, alignment: HeroColumnAlignment,
    leadIn: String? = nil,
    onOpenMetadata: @escaping (ItemMetadataLink) -> Void, isBreadcrumb: Bool = false
  ) {
    self.links = links
    self.placeholder = placeholder
    self.prominence = prominence
    self.alignment = alignment
    self.leadIn = leadIn
    self.onOpenMetadata = onOpenMetadata
    self.isBreadcrumb = isBreadcrumb
  }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var isExpanded = false

  /// The padding that shapes a credit name's hit region inside the `minimumTouchTarget` frame
  /// each name is given. Subheadline text is about 20pt tall, so the padding carries the target
  /// most of the way there and the frame guarantees the rest at every type size.
  private static let touchPadding: CGFloat = WhirrSpacing.xSmall - 1
  /// Split either side of a name, so the gap between two names is the whole value.
  private static let gap: CGFloat = WhirrSpacing.xSmall
  /// Between the lines of one wrapped credit. Negative: each name sits in a
  /// `minimumTouchTarget`-tall row around ~20pt of text, 24pt apart before this pulls them back,
  /// which would equal the gap between credits. The 8pt overlap leaves 36pt of uncontested target.
  private static let rowSpacing: CGFloat = -WhirrSpacing.xSmall
  /// Between credits. The `minimumTouchTarget` frame is the hit region, not the layout height;
  /// pulled back 6pt each side, lines sit at a 32pt pitch (about twice the subheadline's line
  /// height, where a labelled stack reads as one block). Frames overlap 12pt and the later line
  /// wins, leaving 32pt of uncontested target. At full height, series, author and narrator would
  /// each spend 44pt on ~20pt of text and push the play capsule under the fold.
  private static let verticalInset: CGFloat = -(WhirrMetric.minimumTouchTarget - rowPitch) / 2
  /// The layout height one single-row credit line occupies.
  static let rowPitch: CGFloat = 32

  /// Opening the line adds rows under the block, and the hero and everything below move for it.
  /// A short fade-through rather than a slide, so the names appear where they will stay and the
  /// play button does not slide under a thumb on its way to it.
  private static func expansionAnimation(reduceMotion: Bool) -> Animation? {
    reduceMotion ? nil : .easeOut(duration: 0.18)
  }

  var body: some View {
    let visible = ItemMetadataLinkPresentation.visibleLinks(links, isExpanded: isExpanded)
    let hidden = ItemMetadataLinkPresentation.hiddenCount(links, isExpanded: isExpanded)

    // A centred hero has to centre each wrapped row, not just the block. Row-centering would
    // indent short rows in a leading column, so the flow's row alignment follows the column's.
    let flow = FlowRowLayout(
      alignment: alignment == .center ? .center : .leading, rowSpacing: Self.rowSpacing)

    return flow {
      if let leadIn {
        Text(leadIn)
          .fontWeight(.regular)
          .foregroundStyle(WhirrMetadataProminence.creditLeadIn.adaptiveStyle)
          .padding(.horizontal, Self.gap / 2)
          .accessibilityHidden(true)
      }
      // A credit whose value has not arrived reserves its row with the field's own name. It is
      // read, not opened, as there is no collection behind a name nobody has supplied.
      if links.isEmpty {
        Text(placeholder ?? " ")
          .fontWeight(.semibold)
          .foregroundStyle(prominence.adaptiveStyle)
          .padding(.vertical, Self.touchPadding)
          .padding(.horizontal, Self.gap / 2)
          .frame(minHeight: WhirrMetric.minimumTouchTarget)
      }
      ForEach(Array(visible.enumerated()), id: \.offset) { index, link in
        Button {
          onOpenMetadata(link)
        } label: {
          Text(
            ItemMetadataLinkPresentation.label(
              for: link, at: index, of: visible, hasOverflow: hidden > 0)
          )
          .fontWeight(.semibold)
          .underline(isBreadcrumb)
          .foregroundStyle(prominence.adaptiveStyle)
          .lineLimit(
            ItemDetailHeroTextPresentation.creditNameLineLimit(
              isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
          )
          .padding(.vertical, Self.touchPadding)
          .padding(.horizontal, Self.gap / 2)
          .frame(minHeight: WhirrMetric.minimumTouchTarget)
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // The trailing comma is punctuation for the eye only.
        .accessibilityLabel(accessibilityLabel(for: link))
        .accessibilityHint(accessibilityHint(for: link))
      }
      if hidden > 0 || (isExpanded && overflowsWhenCollapsed) {
        Button {
          withAnimation(Self.expansionAnimation(reduceMotion: reduceMotion)) {
            isExpanded.toggle()
          }
        } label: {
          // A step back from the names: it is the line's own control, not another person.
          Text(
            isExpanded
              ? ItemMetadataLinkPresentation.collapseLabel
              : ItemMetadataLinkPresentation.overflowLabel(hidden: hidden)
          )
          .fontWeight(.semibold)
          .foregroundStyle(WhirrMetadataProminence.creditLeadIn.adaptiveStyle)
          .lineLimit(1)
          .padding(.vertical, Self.touchPadding)
          .padding(.horizontal, Self.gap / 2)
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(
          isExpanded ? "Shows fewer names" : "Shows the remaining \(hidden) names")
      }
    }
    .font(isBreadcrumb ? WhirrTypeToken.caption.font : WhirrTypeToken.subheadline.font)
    .padding(.vertical, Self.verticalInset)
    .multilineTextAlignment(alignment.textAlignment)
    .opacity(links.isEmpty ? 0 : 1)
    .allowsHitTesting(links.isEmpty == false)
    .accessibilityHidden(links.isEmpty)
  }

  /// Whether this line would be truncated if closed. The collapse control needs this because once
  /// the line is open nothing is hidden.
  private var overflowsWhenCollapsed: Bool {
    ItemMetadataLinkPresentation.hiddenCount(links, isExpanded: false) > 0
  }

  private func accessibilityLabel(for link: ItemMetadataLink) -> String {
    guard let leadIn else { return link.displayName }
    return "\(leadIn) \(link.displayName)"
  }

  private func accessibilityHint(for link: ItemMetadataLink) -> String {
    switch link.destination {
    case .author: "Opens books by this author"
    case .series: "Opens this series"
    case .narrator: "Opens audiobooks by this narrator"
    }
  }
}

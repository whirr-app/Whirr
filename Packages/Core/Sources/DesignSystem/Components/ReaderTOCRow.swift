import SwiftUI

/// The TOC keeps its compact, one-line row at standard Dynamic Type sizes. At accessibility
/// sizes, the title gets unbounded height and the page label moves below it, so neither piece of
/// reader-essential copy has to compete for a single horizontal line. This is local to the TOC,
/// like `ListeningQueueRowLayoutValues`: `MediaRowLayoutValues` leaves essential media
/// text unbounded at both size legs, while this row must preserve its existing standard cap.
public struct ReaderTOCRowLayoutValues: Sendable, Equatable {
  public let axis: MediaRowLayoutAxis
  public let titleLineLimit: Int?
  public let titleLayoutPriority: Double
  public let pageLabelLineLimit: Int?
  public let pageLabelLayoutPriority: Double
  public let pageLabelUsesFixedWidth: Bool

  public static func resolve(isAccessibilitySize: Bool) -> ReaderTOCRowLayoutValues {
    ReaderTOCRowLayoutValues(
      axis: isAccessibilitySize ? .vertical : .horizontal,
      titleLineLimit: isAccessibilitySize ? nil : 1,
      titleLayoutPriority: isAccessibilitySize ? 1 : 0,
      pageLabelLineLimit: isAccessibilitySize ? nil : 1,
      pageLabelLayoutPriority: isAccessibilitySize ? 0 : 1,
      pageLabelUsesFixedWidth: isAccessibilitySize == false)
  }
}

/// One table-of-contents entry. The row is content-layer UI, so it uses the reader palette but no
/// glass surface. Depth is represented by indentation and the current chapter has both an
/// explicit indicator and the selected accessibility trait.
public struct ReaderTOCRow: View {
  public static let titleTextToken: WhirrTypeToken = .body

  public let title: String
  public let pageLabel: String?
  public let depth: Int
  public let accessibilityValue: String
  public let isCurrent: Bool
  public let currentIndicatorSystemImage: String
  public let theme: ReaderTheme
  public let onSelect: () -> Void

  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  public let minimumHitTargetHeight: CGFloat = WhirrMetric.minimumTouchTarget

  public var indentation: CGFloat {
    CGFloat(max(depth, 0)) * WhirrSpacing.medium
  }

  /// The row's own margin from the edge of its container, which the depth indentation adds to
  /// rather than replaces. A top-level chapter has no indentation and still needs a margin.
  public var horizontalInset: CGFloat { WhirrSpacing.medium }

  public var leadingInset: CGFloat { horizontalInset + indentation }

  public var accessibilityTraits: AccessibilityTraits {
    isCurrent ? AccessibilityTraits.isButton.union(.isSelected) : .isButton
  }

  public var titleColorRole: WhirrRGBColor {
    isCurrent ? theme.palette.accent : theme.palette.foreground
  }

  public var pageLabelColorRole: WhirrRGBColor? {
    guard pageLabel != nil else { return nil }
    return isCurrent ? theme.palette.accent : theme.palette.secondaryForeground
  }

  public var selectedBackgroundCornerRadius: CGFloat? { nil }

  /// The indicator is decoration: the row already announces its current state through the
  /// selected trait, so exposing the glyph would add a second, unlabelled element.
  public var indicatorAccessibilityHidden: Bool { true }

  public var showsCurrentIndicator: Bool { isCurrent }

  /// Every row reserves this, current or not. Adding the glyph only to the current row moved that
  /// row's page number out of line with the rest of the list as the reader turned pages.
  public var indicatorSlotWidth: CGFloat { WhirrSpacing.medium }

  /// The page number owns the row's trailing edge (the column the eye scans down), so the
  /// indicator sits inboard of it rather than pushing it off the edge.
  public var indicatorPrecedesPageLabel: Bool { true }

  public var dividerRole: WhirrRGBColor {
    nonTextContrastColor(
      preferred: theme.palette.divider,
      on: theme.palette.background)
  }

  public var dividerSpansFullWidth: Bool { true }

  public var dividerLeadingInset: CGFloat { 0 }

  public var dividerHeight: CGFloat { 0.5 }

  private var layoutValues: ReaderTOCRowLayoutValues {
    ReaderTOCRowLayoutValues.resolve(isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
  }

  public var layoutAxis: MediaRowLayoutAxis { layoutValues.axis }

  public var titleLineLimit: Int? { layoutValues.titleLineLimit }

  public var titleLayoutPriority: Double { layoutValues.titleLayoutPriority }

  public var pageLabelLineLimit: Int? { layoutValues.pageLabelLineLimit }

  public var pageLabelLayoutPriority: Double { layoutValues.pageLabelLayoutPriority }

  public var pageLabelUsesFixedWidth: Bool { layoutValues.pageLabelUsesFixedWidth }

  public init(
    title: String,
    pageLabel: String? = nil,
    depth: Int,
    accessibilityValue: String,
    isCurrent: Bool,
    currentIndicatorSystemImage: String,
    theme: ReaderTheme,
    onSelect: @escaping () -> Void
  ) {
    self.title = title
    self.pageLabel = pageLabel
    self.depth = depth
    self.accessibilityValue = accessibilityValue
    self.isCurrent = isCurrent
    self.currentIndicatorSystemImage = currentIndicatorSystemImage
    self.theme = theme
    self.onSelect = onSelect
  }

  public var body: some View {
    Button(action: onSelect) {
      rowContent
        .padding(.leading, leadingInset)
        .padding(.trailing, horizontalInset)
        .frame(maxWidth: .infinity, minHeight: minimumHitTargetHeight, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(dividerRole.color)
        .frame(maxWidth: .infinity)
        .frame(height: dividerHeight)
    }
    .accessibilityLabel(title)
    .accessibilityValue(accessibilityValue)
    .accessibilityAddTraits(accessibilityTraits)
  }

  @ViewBuilder private var rowContent: some View {
    if layoutAxis == .vertical {
      VStack(alignment: .leading, spacing: WhirrSpacing.small) {
        HStack(spacing: WhirrSpacing.small) {
          titleContent
          indicatorContent
        }
        pageLabelContent
      }
    } else {
      HStack(spacing: WhirrSpacing.small) {
        titleContent
        indicatorContent
        pageLabelContent
      }
    }
  }

  private var titleContent: some View {
    Text(title)
      .font(Self.titleTextToken.font)
      .foregroundStyle(titleColorRole.color)
      .lineLimit(titleLineLimit)
      .truncationMode(.tail)
      .fixedSize(horizontal: false, vertical: true)
      .layoutPriority(titleLayoutPriority)
      .multilineTextAlignment(.leading)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var indicatorContent: some View {
    Image(systemName: currentIndicatorSystemImage)
      .font(.body.weight(.semibold))
      .foregroundStyle(theme.palette.accentColor)
      .opacity(showsCurrentIndicator ? 1 : 0)
      .frame(width: indicatorSlotWidth, alignment: .trailing)
      .accessibilityHidden(indicatorAccessibilityHidden)
  }

  @ViewBuilder private var pageLabelContent: some View {
    if let pageLabel {
      if layoutAxis == .vertical {
        pageLabelText(pageLabel)
          .frame(maxWidth: .infinity, alignment: .trailing)
      } else {
        pageLabelText(pageLabel)
      }
    }
  }

  private func pageLabelText(_ pageLabel: String) -> some View {
    Text(pageLabel)
      .font(Self.titleTextToken.font)
      .foregroundStyle(pageLabelColorRole?.color ?? theme.palette.foregroundColor)
      .lineLimit(pageLabelLineLimit)
      .fixedSize(horizontal: pageLabelUsesFixedWidth, vertical: pageLabelUsesFixedWidth == false)
      .layoutPriority(pageLabelLayoutPriority)
      .multilineTextAlignment(.trailing)
  }
}

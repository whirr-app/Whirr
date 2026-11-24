import SwiftUI

/// Presentation styles for the shared offline/finished badge. Browse rows use a glyph; detail keeps
/// the labelled capsule.
public enum RowBadgeStyle: Sendable, Equatable {
  case row
  case detail

  public static let iconSlotSize: CGFloat = 24

  public var isIconOnly: Bool { self == .row }
  public var showsLabel: Bool { self == .detail }
}

/// The "downloaded"/"available offline" badge shown on browse/search rows and item detail. Label
/// and icon are caller-supplied (`ItemDownloadModel.isDownloaded`/`isAvailableOffline` own the
/// condition, `ItemDownloadCopy` owns the copy), so this view has no state copy of its own.
public struct OfflineBadgeView: View {
  public let label: String
  public let systemImage: String
  /// Kept for source compatibility with existing callers. `true` maps to `RowBadgeStyle.row`.
  public let isCompact: Bool

  public init(label: String, systemImage: String, isCompact: Bool = false) {
    self.label = label
    self.systemImage = systemImage
    self.isCompact = isCompact
  }

  public init(label: String, systemImage: String, style: RowBadgeStyle) {
    self.init(label: label, systemImage: systemImage, isCompact: style.isIconOnly)
  }

  public var style: RowBadgeStyle { isCompact ? .row : .detail }
  public var isIconOnly: Bool { style.isIconOnly }
  public var showsLabel: Bool { style.showsLabel }
  public var accessibilityLabel: String { label }

  @ViewBuilder
  public var body: some View {
    if isIconOnly {
      Image(systemName: systemImage)
        .font(WhirrTypeToken.caption.font)
        .foregroundStyle(.secondary)
        .frame(width: RowBadgeStyle.iconSlotSize, height: RowBadgeStyle.iconSlotSize)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
    } else {
      Label(label, systemImage: systemImage)
        .font(WhirrTypeToken.caption.font)
        .foregroundStyle(AnyShapeStyle(.primary))
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, WhirrSpacing.xSmall)
        .padding(.vertical, WhirrSpacing.xxSmall)
        .badgeBackground(in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }
  }
}

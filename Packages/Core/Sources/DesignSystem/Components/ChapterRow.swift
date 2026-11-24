import SwiftUI

/// One row in a chapter list. It owns the shared visual treatment; callers supply the already
/// formatted timing and the accessibility copy because the detail screen and player sheet retain
/// different VoiceOver phrasing.
public struct ChapterRow: View {
  public let title: String
  public let timingText: String
  public let accessibilityLabel: String
  public let accessibilityValue: String
  public let accessibilityIdentifier: String?
  public let isCurrent: Bool
  public let isCompleted: Bool
  public let trailingIndicatorSystemImage: String?
  public let onSelect: () -> Void

  public let minimumHitTargetHeight: CGFloat = WhirrMetric.minimumTouchTarget

  /// The semantic foreground for the title. A completed chapter reads as completed through both
  /// this secondary treatment and the caller-supplied trailing indicator.
  public var titleColorToken: WhirrColorToken {
    isCompleted ? .textSecondary : .textPrimary
  }

  /// Current chapters use a stronger title weight so the current state is not conveyed by color
  /// or glyph alone.
  public var titleWeight: Font.Weight {
    isCurrent ? .semibold : .regular
  }

  /// The current indicator follows the caller's live tint; a completed indicator is secondary.
  public var indicatorUsesTint: Bool {
    isCurrent
  }

  public var showsTrailingIndicator: Bool {
    trailingIndicatorSystemImage != nil
  }

  /// Compatibility view of the current-indicator input. New call sites should use the optional
  /// trailing indicator so current and completed states can share the row.
  public var currentIndicatorSystemImage: String {
    trailingIndicatorSystemImage ?? ""
  }

  public init(
    title: String,
    timingText: String,
    isCurrent: Bool,
    isCompleted: Bool = false,
    trailingIndicatorSystemImage: String? = nil,
    accessibilityLabel: String,
    accessibilityValue: String,
    accessibilityIdentifier: String? = nil,
    onSelect: @escaping () -> Void
  ) {
    self.title = title
    self.timingText = timingText
    self.accessibilityLabel = accessibilityLabel
    self.accessibilityValue = accessibilityValue
    self.accessibilityIdentifier = accessibilityIdentifier
    self.isCurrent = isCurrent
    self.isCompleted = isCompleted
    self.trailingIndicatorSystemImage = trailingIndicatorSystemImage
    self.onSelect = onSelect
  }

  /// For callers that only supply a title and current indicator. Production chapter screens use
  /// the richer initialiser above.
  public init(
    title: String,
    accessibilityValue: String,
    isCurrent: Bool,
    currentIndicatorSystemImage: String,
    onSelect: @escaping () -> Void
  ) {
    self.init(
      title: title,
      timingText: "",
      isCurrent: isCurrent,
      isCompleted: false,
      trailingIndicatorSystemImage: isCurrent ? currentIndicatorSystemImage : nil,
      accessibilityLabel: title,
      accessibilityValue: accessibilityValue,
      onSelect: onSelect
    )
  }

  public var body: some View {
    accessibleButton
      .buttonStyle(.plain)
      .accessibilityLabel(accessibilityLabel)
      .accessibilityValue(accessibilityValue)
      .accessibilityAddTraits(
        isCurrent ? AccessibilityTraits.isButton.union(.isSelected) : .isButton)
  }

  @ViewBuilder
  private var accessibleButton: some View {
    if let accessibilityIdentifier {
      baseButton.accessibilityIdentifier(accessibilityIdentifier)
    } else {
      baseButton
    }
  }

  private var baseButton: some View {
    Button(action: onSelect) {
      HStack(spacing: WhirrSpacing.medium) {
        VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
          Text(title)
            .font(WhirrTypeToken.body.font.weight(titleWeight))
            .foregroundStyle(titleColorToken.color)
            .lineLimit(2)

          if timingText.isEmpty == false {
            Text(timingText)
              .font(WhirrTypeToken.caption.font)
              .foregroundStyle(WhirrColorToken.textSecondary.color)
          }
        }

        Spacer(minLength: WhirrSpacing.small)

        if let trailingIndicatorSystemImage {
          trailingIndicator(trailingIndicatorSystemImage)
        }
      }
      .frame(minHeight: minimumHitTargetHeight)
      .contentShape(Rectangle())
    }
  }

  @ViewBuilder
  private func trailingIndicator(_ systemImage: String) -> some View {
    if indicatorUsesTint {
      Image(systemName: systemImage)
        .font(WhirrTypeToken.subheadline.font.weight(.semibold))
        .foregroundStyle(.tint)
        .accessibilityHidden(true)
    } else {
      Image(systemName: systemImage)
        .font(WhirrTypeToken.subheadline.font)
        .foregroundStyle(WhirrColorToken.textSecondary.color)
        .accessibilityHidden(true)
    }
  }
}

/// A chapter list: a plain, non-glass scroll of `ChapterRow`s. It is content layer, not floating,
/// so it never uses glass (see ARCHITECTURE.md). Keeps the caller's chapter order, which is also
/// the VoiceOver navigation order.
public struct ChapterListView: View {
  public let rows: [ChapterRow]

  public init(rows: [ChapterRow]) {
    self.rows = rows
  }

  public var body: some View {
    ScrollView {
      LazyVStack(spacing: 0) {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
          row
        }
      }
    }
  }
}

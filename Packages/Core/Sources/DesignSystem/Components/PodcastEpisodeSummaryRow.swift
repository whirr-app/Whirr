import SwiftUI

/// A compact, selectable summary of one podcast episode. The caller supplies the artwork size,
/// display strings, accessibility label, and selection action; context menus and other surface
/// actions remain outside this shared row.
public struct PodcastEpisodeSummaryRow<Cover: View>: View {
  public let title: String
  public let showTitle: String
  public let dateText: String
  public let durationText: String
  public let accessibilityLabel: String
  public let coverSize: CGFloat
  public let contentPadding: EdgeInsets
  public let cover: Cover
  public let onSelect: () -> Void

  public init(
    title: String,
    showTitle: String,
    dateText: String,
    durationText: String,
    accessibilityLabel: String,
    coverSize: CGFloat,
    contentPadding: EdgeInsets = EdgeInsets(),
    @ViewBuilder cover: () -> Cover,
    onSelect: @escaping () -> Void
  ) {
    self.title = title
    self.showTitle = showTitle
    self.dateText = dateText
    self.durationText = durationText
    self.accessibilityLabel = accessibilityLabel
    self.coverSize = coverSize
    self.contentPadding = contentPadding
    self.cover = cover()
    self.onSelect = onSelect
  }

  public var metadataText: String {
    [dateText, durationText].joined(separator: " · ")
  }

  /// The text the row visibly renders, in reading order. The accessibility label is caller-owned
  /// because the App presentation can carry an additional optional episode subtitle.
  public var visibleText: [String] {
    [title, showTitle, dateText, durationText]
  }

  public var body: some View {
    Button(action: onSelect) {
      HStack(alignment: .top, spacing: WhirrSpacing.small) {
        cover
          .frame(width: coverSize, height: coverSize)

        VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
          Text(title)
            .font(WhirrTypeToken.headline.font)
            .foregroundStyle(.primary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)

          Text(showTitle)
            .font(WhirrTypeToken.subheadline.font)
            .foregroundStyle(WhirrColorToken.textSecondary.color)
            .lineLimit(1)

          Text(metadataText)
            .font(WhirrTypeToken.caption.font)
            .foregroundStyle(WhirrColorToken.textSecondary.color)
            .lineLimit(1)
        }

        Spacer(minLength: WhirrSpacing.small)
      }
      .padding(contentPadding)
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }
}

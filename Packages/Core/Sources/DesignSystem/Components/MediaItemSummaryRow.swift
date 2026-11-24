import SwiftUI

/// The shared artwork-and-copy portion of a media item row. The cover and the two accessory
/// regions are caller-owned, so surfaces keep their own badges and state without this component
/// knowing about AppModel.
///
/// Surface actions, list insets, swipe actions, context menus, and accessibility identifiers stay
/// at the call site. The caller supplies the composed accessibility label because Home and
/// Downloads append different storage details.
public struct MediaItemSummaryRow<Cover: View, InlineContent: View, TrailingContent: View>: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  public let title: String
  public let subtitle: String?
  public let metadata: String
  public let accessibilityLabel: String
  public let coverSize: CGFloat
  public let wash: CoverWash?
  public let eyebrow: String?
  public let cover: Cover
  public let inlineContent: InlineContent
  public let trailingContent: TrailingContent

  public init(
    title: String,
    subtitle: String?,
    metadata: String,
    accessibilityLabel: String,
    coverSize: CGFloat,
    wash: CoverWash? = nil,
    eyebrow: String? = nil,
    @ViewBuilder cover: () -> Cover,
    @ViewBuilder inlineContent: () -> InlineContent,
    @ViewBuilder trailingContent: () -> TrailingContent
  ) {
    self.title = title
    self.subtitle = subtitle
    self.metadata = metadata
    self.accessibilityLabel = accessibilityLabel
    self.coverSize = coverSize
    self.wash = wash
    self.eyebrow = eyebrow
    self.cover = cover()
    self.inlineContent = inlineContent()
    self.trailingContent = trailingContent()
  }

  public var accentColor: Color {
    wash?.accentColor ?? WhirrColorToken.brandInk.color
  }

  /// Whether the accent came from the wash rather than the brand-ink fallback.
  public var usesWashAccent: Bool {
    wash?.accentColor != nil
  }

  public var showsEyebrow: Bool {
    wash != nil && !(eyebrow?.isEmpty ?? true)
  }

  /// This row never fills its own card. See `PodcastEpisodeCardRow.paintsCardBackground` and
  /// `EditorialCardListRowModifier` for why the fill belongs to the call site.
  public static var paintsCardBackground: Bool { false }

  public var isCard: Bool {
    wash != nil
  }

  /// How the fixed-size cover sits against the variable-height copy column.
  ///
  /// Centred, not top-aligned. A title that wraps to `titleLineLimit` lines grows the column past
  /// the cover, and top alignment would pin the artwork opposite the first line so it sits high in
  /// its own row.
  public static var coverAlignment: VerticalAlignment {
    ArtworkLedRowMetrics.artworkAlignment
  }

  /// Standard-size titles get a second line because a single elided line loses distinguishing
  /// words. Accessibility sizes remove this cap so enlarged titles can remain readable in full.
  public static var titleLineLimit: Int { 2 }

  /// How many title lines the copy column is sized for, whatever the title actually wraps to.
  ///
  /// Reserving the full `titleLineLimit` keeps every card in a list the same height, with the real
  /// copy centred in that space. Accessibility sizes reserve nothing: their titles are uncapped
  /// and the card must grow to fit them.
  public static func reservedTitleLines(isAccessibilitySize: Bool) -> Int? {
    isAccessibilitySize ? nil : titleLineLimit
  }

  /// The text the row visibly renders, in reading order. Also the semantic surface the component
  /// tests use; the accessory slots stay generic SwiftUI content.
  public var visibleText: [String] {
    var text: [String] = []
    if showsEyebrow, let eyebrow {
      text.append(eyebrow)
    }
    text.append(contentsOf: [title, subtitle, metadata].compactMap { $0 })
    return text
  }

  public var hasSubtitle: Bool { subtitle != nil }

  /// Shared by the visible eyebrow and the hidden height sample so the reserved height tracks it.
  private static var eyebrowFont: Font { WhirrTypeToken.subheadline.font.weight(.medium) }

  public var body: some View {
    HStack(alignment: Self.coverAlignment, spacing: WhirrSpacing.small) {
      cover
        .frame(width: coverSize, height: coverSize)

      ZStack(alignment: .leading) {
        if let reservedLines = Self.reservedTitleLines(
          isAccessibilitySize: dynamicTypeSize.isAccessibilitySize)
        {
          heightSample(titleLines: reservedLines)
        }
        copyColumn
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      // At accessibility sizes the complete title and storage metadata need vertical room;
      // preserving the compact line caps would truncate the information used to choose a row.
      .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityLabel)
  }

  /// A hidden stand-in for the copy column with a title of `titleLines` lines. It gives the column
  /// a Dynamic Type-aware height without hard-coding a line height, as `HomeCardView` does. The
  /// accessory slots are left out: a card that shows progress is meant to be taller.
  private func heightSample(titleLines: Int) -> some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
      if showsEyebrow {
        Text(verbatim: "Eyebrow")
          .font(Self.eyebrowFont)
      }
      Text(verbatim: Array(repeating: "Title", count: titleLines).joined(separator: "\n"))
        .font(WhirrTypeToken.headline.font)
      if hasSubtitle {
        Text(verbatim: "Subtitle")
          .font(WhirrTypeToken.subheadline.font)
      }
      Text(verbatim: "Metadata")
        .font(WhirrTypeToken.caption.font)
    }
    .hidden()
    .accessibilityHidden(true)
  }

  private var copyColumn: some View {
    VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
      if showsEyebrow, let eyebrow {
        // Sentence case at subheadline weight, matching `PodcastEpisodeCardRow`'s show line. The
        // artwork already names the work, so this line only confirms the creator.
        Text(eyebrow)
          .font(Self.eyebrowFont)
          .foregroundStyle(WashInk.eyebrow(accentColor, wash: wash))
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
      }

      Text(title)
        .font(WhirrTypeToken.headline.font)
        .foregroundStyle(.primary)
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : Self.titleLineLimit)

      if let subtitle {
        Text(subtitle)
          .font(WhirrTypeToken.subheadline.font)
          .foregroundStyle(WashInk.secondary)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
      }

      HStack(spacing: WhirrSpacing.xSmall) {
        Text(metadata)
          .font(WhirrTypeToken.caption.font)
          .foregroundStyle(WashInk.secondary)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)

        inlineContent

        Spacer(minLength: 0)
      }

      trailingContent
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

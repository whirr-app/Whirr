import SwiftUI

/// One book-search match. The renderer supplies the three text fragments around the match, so the
/// row never has to rediscover a range using a different case-folding or diacritic policy.
public struct ReaderSearchResultRow: View {
  public static let chapterTitleTextToken: WhirrTypeToken = .caption
  public static let snippetTextToken: WhirrTypeToken = .body
  public static let snippetLineLimit = 2

  public let chapterTitle: String?
  public let before: String
  public let highlight: String
  public let after: String
  public let theme: ReaderTheme
  public let onSelect: () -> Void

  public let minimumHitTargetHeight: CGFloat = WhirrMetric.minimumTouchTarget

  /// The three caller-supplied parts remain separate until this value is composed. The match gets
  /// the reader accent directly; no query or range search is involved.
  public var attributedSnippet: AttributedString {
    var value = AttributedString(before)
    var emphasized = AttributedString(highlight)
    emphasized.foregroundColor = theme.palette.accentColor
    value.append(emphasized)
    value.append(AttributedString(after))
    return value
  }

  /// Short value alias for callers/tests that treat the row's snippet as its primary content.
  public var snippet: AttributedString { attributedSnippet }

  public var chapterTitleColorRole: WhirrRGBColor { theme.palette.secondaryForeground }
  public var snippetColorRole: WhirrRGBColor { theme.palette.foreground }
  public var highlightColorRole: WhirrRGBColor { theme.palette.accent }

  public init(
    chapterTitle: String? = nil,
    before: String,
    highlight: String,
    after: String,
    theme: ReaderTheme,
    onSelect: @escaping () -> Void = {}
  ) {
    self.chapterTitle = chapterTitle
    self.before = before
    self.highlight = highlight
    self.after = after
    self.theme = theme
    self.onSelect = onSelect
  }

  public var body: some View {
    Button(action: onSelect) {
      VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
        if let chapterTitle {
          Text(chapterTitle)
            .font(Self.chapterTitleTextToken.font)
            .foregroundStyle(chapterTitleColorRole.color)
            .lineLimit(1)
            .truncationMode(.tail)
        }

        Text(attributedSnippet)
          .font(Self.snippetTextToken.font)
          .foregroundStyle(snippetColorRole.color)
          .lineLimit(Self.snippetLineLimit)
          .truncationMode(.tail)
          .multilineTextAlignment(.leading)
      }
      .frame(maxWidth: .infinity, minHeight: minimumHitTargetHeight, alignment: .leading)
      .padding(.horizontal, WhirrSpacing.medium)
      .padding(.vertical, WhirrSpacing.xSmall)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

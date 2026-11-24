import SwiftUI

/// A library item row: title/author text plus a caller-provided cover slot and progress
/// slot. Callers own the concrete cover/progress content; this type only lays them out.
public struct ItemListRow<Cover: View, Progress: View>: View {
  let title: String
  /// `nil` omits the author text, while an empty string still claims a line's height. Progress
  /// content shares that second line and remains visible even when the author is `nil`.
  let author: String?
  let cover: Cover
  let progress: Progress

  /// Status glyphs occupy a taller slot than the caption. Top alignment keeps adding or removing
  /// one from changing the caption's distance from the title.
  var subtitleStatusAlignment: VerticalAlignment { .top }

  public init(
    title: String,
    author: String?,
    @ViewBuilder cover: () -> Cover,
    @ViewBuilder progress: () -> Progress
  ) {
    self.title = title
    self.author = author
    self.cover = cover()
    self.progress = progress()
  }

  public var body: some View {
    HStack(spacing: WhirrSpacing.small) {
      cover
        .frame(width: WhirrMetric.minimumTouchTarget, height: WhirrMetric.minimumTouchTarget)

      VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
        Text(title)
          .font(WhirrTypeToken.headline.font)
        HStack(alignment: subtitleStatusAlignment, spacing: WhirrSpacing.xxSmall) {
          if let author {
            Text(author)
              .font(WhirrTypeToken.caption.font)
              .foregroundStyle(WashInk.secondary)
          }

          Spacer(minLength: WhirrSpacing.small)

          progress
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.vertical, WhirrSpacing.xSmall)
  }
}

import SwiftUI

/// Placeholder shown while a real cover image is loading or unavailable. The accessibility
/// label always comes from the caller (e.g. the item's title). This view has no copy of its own
/// and is hidden from accessibility when no label is supplied.
///
/// While artwork is in flight it stays a quiet blank tile, so a scrolling grid never flashes
/// generated art before the real cover. The caller passes `.missing` only once the pipeline has
/// resolved empty, and the item then gets a generated paperback cover (`GeneratedCoverArtView`).
public struct CoverPlaceholder: View {
  public enum State: Sendable {
    case loading
    case missing
  }

  let accessibilityLabel: String?
  let title: String?
  let author: String?
  let state: State

  public init(
    accessibilityLabel: String? = nil,
    title: String? = nil,
    author: String? = nil,
    state: State = .loading
  ) {
    self.accessibilityLabel = accessibilityLabel
    self.title = title
    self.author = author
    self.state = state
  }

  /// Non-nil only when there is something to draw: artwork resolved as absent, and a title to set.
  var generatedArt: GeneratedCoverArt? {
    guard state == .missing,
      let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    else {
      return nil
    }
    return GeneratedCoverArt(title: title, author: author)
  }

  public var body: some View {
    Group {
      if let generatedArt {
        GeneratedCoverArtView(art: generatedArt)
      } else {
        RoundedRectangle(cornerRadius: WhirrSpacing.xxSmall)
          .fill(WhirrColorToken.surfaceSecondary.color)
          .overlay {
            Image(systemName: "book.closed")
              .foregroundStyle(WhirrColorToken.textSecondary.color)
          }
      }
    }
    .modifier(CoverPlaceholderAccessibility(label: accessibilityLabel))
  }
}

private struct CoverPlaceholderAccessibility: ViewModifier {
  let label: String?

  func body(content: Content) -> some View {
    if let label {
      content.accessibilityLabel(label)
    } else {
      content.accessibilityHidden(true)
    }
  }
}

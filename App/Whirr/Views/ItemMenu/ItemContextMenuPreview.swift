import ABSApi
import AppModel
import SwiftUI

/// The menu's lifted preview. Also a child view, so the high-fidelity `CoverImageView` request is
/// only constructed when the preview is built, never once per row on the scroll path.
struct ItemContextMenuPreview: View {
  let itemID: String
  let title: String
  let author: String?
  let loadsExtras: Bool
  let coverClient: any ArtworkServing
  let source: ArtworkSource?
  let revision: ArtworkRevision
  let actions: ItemActionsModel
  /// Whether the lifted card takes the cover's portrait shape (ebooks) or stays square (audiobook,
  /// podcast). Fixed at construction from the row's `category` (a plain value), never from
  /// observable state, so this stays off the scroll path (see the modifier's note).
  let shapesToCover: Bool

  /// A portrait card for an ebook, a square card otherwise. The longest edge stays at 220 points
  /// so the preview keeps a meaningful artwork lift without pushing the menu below the screen.
  /// The card is shaped to the cover because iOS renders the lift on its own neutral platter, so
  /// any margin would read as a bar.
  private var frameSize: CGSize {
    ItemContextMenuPresentation.previewFrameSize(shapesToCover: shapesToCover)
  }

  var body: some View {
    let size = frameSize
    CoverImageView(
      itemID: itemID,
      title: title,
      // Keep the request on the item-detail key even though the rendered preview is smaller.
      // Keying this by 220 would create another cache/decode variant for the same cover.
      displaySize: ItemDetailView.coverDisplaySize,
      client: coverClient,
      source: source,
      author: author,
      role: .detail,
      presentation: .fill,
      cornerRadius: 22,
      revision: revision
    )
    .frame(width: size.width, height: size.height)
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    .accessibilityLabel("\(title) cover")
    .task {
      guard loadsExtras else { return }
      await actions.loadExtrasIfNeeded(itemID: itemID)
    }
  }
}

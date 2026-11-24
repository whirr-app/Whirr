import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

struct HomeShelfCover: View {
  let itemID: String
  let title: String
  let author: String?
  let presentation: CoverImageView.Presentation
  let client: any ArtworkServing
  let source: ArtworkSource?
  let revision: ArtworkRevision
  let layout: HomeViewPresentation.ShelfLayout

  var body: some View {
    let frame = HomeViewPresentation.coverFrame(forWidth: layout.drawnCoverWidth)
    CoverImageView(
      itemID: itemID,
      title: title,
      // The drawn cover follows the resolved card, but the request stays at the existing 140 pt
      // tier. A larger draw can reuse that artwork; changing this request would create another
      // cache variant and make every shelf width a separate prefetch path.
      displaySize: HomeView.cardCoverSize,
      client: client,
      source: source,
      author: author,
      role: .homeCard,
      presentation: presentation,
      artworkGlow: true,
      // `HomeCardView` leaves its cover unclipped so the glow can reach the card, so the cover
      // rounds itself at the card slot's radius.
      cornerRadius: WhirrSpacing.xSmall,
      revision: revision
    )
    // Not `.clipped()`: it would cut the glow off at the cover's frame. The cover's own clip
    // already bounds a filled image.
    .frame(
      width: frame.width,
      height: frame.height
    )
  }
}

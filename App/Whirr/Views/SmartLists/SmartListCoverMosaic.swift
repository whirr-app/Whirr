import ABSApi
import AppModel
import DesignSystem
import Persistence
import SwiftUI

/// The picture that stands for a list: the covers of its leading shows in a two-by-two grid, one
/// cover when fewer than four shows are in it, and a plain tile while it matches nothing.
struct SmartListCoverMosaic: View {
  static let rowSize: CGFloat = 56

  let episodes: [SmartListEpisode]
  let client: any ArtworkServing
  var size: CGFloat = SmartListCoverMosaic.rowSize

  var body: some View {
    Group {
      switch SmartListsPresentation.mosaicLayout(coverCount: episodes.count) {
      case .grid:
        let side = size / 2
        VStack(spacing: 0) {
          HStack(spacing: 0) {
            cover(episodes[0], side: side)
            cover(episodes[1], side: side)
          }
          HStack(spacing: 0) {
            cover(episodes[2], side: side)
            cover(episodes[3], side: side)
          }
        }
      case .single:
        cover(episodes[0], side: size)
      case .placeholder:
        ZStack {
          Rectangle().fill(.quaternary)
          Image(systemName: "line.3.horizontal.decrease")
            .font(.title3)
            .foregroundStyle(.secondary)
        }
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: WhirrSpacing.xSmall, style: .continuous))
    .accessibilityHidden(true)
  }

  /// Every tile asks for the cover at the mosaic's full size, so a show's cover is one cache entry
  /// whether it fills the tile or a quarter of it.
  private func cover(_ episode: SmartListEpisode, side: CGFloat) -> some View {
    let home = episode.homeEpisode
    return CoverImageView(
      itemID: home.itemID, title: home.showTitle, displaySize: size, client: client,
      source: home.providerArtworkSource, author: home.showAuthor, cornerRadius: 0,
      revision: home.artworkRevision
    )
    .frame(width: side, height: side)
  }
}

#if DEBUG || PERF_INVESTIGATION
  import ABSApi
  import DesignSystem
  import Persistence
  import SwiftUI

  /// The cheapest title tile that still shows a cover, title and subtitle. Selected by
  /// `WHIRR_ABLATE_TILE_FLOOR`, never built into release.
  ///
  /// Bounds the achievable cost of the 1.4 ms per tile: single-modifier ablations all came back
  /// flat or negative, so this removes everything at once (button, context menu, combined
  /// accessibility element, zoom source, all of `CoverImageView.artworkBody`), leaving one `Image`
  /// and two `Text`s. Artwork comes straight from `PreparedArtworkCache` (a real-library sweep was
  /// served synchronously on essentially every tile); a miss draws a plain fill. The directional
  /// prefetch `onAppear` stays, or the arm would measure a grid of grey rectangles.
  struct LibraryTitleGridFloorTile: View {
    let item: ItemSummary
    let tileWidth: CGFloat
    let prefetchIndex: Int
    let orderedIDs: [String]
    let revisionsByID: [String: ArtworkRevision]
    let coverClient: any ArtworkServing
    let artworkPrefetcher: DirectionalArtworkPrefetcher

    @Environment(\.displayScale) private var displayScale

    var body: some View {
      VStack(alignment: .leading, spacing: WhirrSpacing.xxSmall) {
        cover

        Text(item.title)
          .font(WhirrTypeToken.headline.font)
          .foregroundStyle(WhirrColorToken.textPrimary.color)
          .lineLimit(2, reservesSpace: true)

        Text(item.author ?? "")
          .font(WhirrTypeToken.subheadline.font)
          .foregroundStyle(WhirrColorToken.textSecondary.color)
          .lineLimit(2, reservesSpace: true)
      }
      .frame(width: tileWidth, alignment: .topLeading)
      .onAppear {
        artworkPrefetcher.observe(
          visibleIndex: prefetchIndex,
          orderedIDs: orderedIDs,
          displaySize: LibraryBrowseLayoutPresentation.regularCoverMinimumWidth,
          displayScale: displayScale,
          client: coverClient, revisionsByID: revisionsByID)
      }
    }

    @ViewBuilder
    private var cover: some View {
      let key = CoverImageView.artworkKey(
        itemID: item.serverItemId,
        client: coverClient,
        source: nil,
        displaySize: LibraryBrowseLayoutPresentation.regularCoverMinimumWidth,
        displayScale: displayScale,
        role: .homeCard,
        revision: item.artworkRevision)

      if let image = PreparedArtworkCache.shared.image(for: key) {
        Image(uiImage: image)
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: tileWidth, height: tileWidth)
      } else {
        WhirrColorToken.surfaceSecondary.color
          .frame(width: tileWidth, height: tileWidth)
      }
    }
  }
#endif

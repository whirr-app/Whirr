import ABSApi
import UIKit

/// The one cover every saved palette is extracted from, whichever surface asks.
///
/// Surfaces share one saved row per item, so they must agree on the pixels. At the 44 point
/// library thumbnail the server's WebP smears fine coloured line work into black, giving a
/// different colour from the detail page; from the home card up the source size stops mattering.
/// Stays cache-only (`CoverPaletteService.CoverBytes`): home card bytes if on disk, else the
/// displayed cover if it can stand in, else nothing until a later visit finds the card cached.
enum CoverPaletteSource {
  /// The home card's width on this device. Resolved once from the trait context, as the cover pass
  /// resolves the widths it caches, so both name the same key. A caller's `displayScale` is not
  /// used: some surfaces build their requests before the environment's scale arrives.
  static let cardPixelWidth: Int = {
    let traitScale = Double(UITraitCollection.current.displayScale)
    return ArtworkVariant.homeCard(
      displaySize: Double(HomeView.cardCoverSize), displayScale: traitScale > 0 ? traitScale : 3
    ).pixelWidth
  }()

  /// The home card key for the same artwork as `key`.
  static func cardKey(for key: ArtworkKey) -> ArtworkKey {
    cardKey(source: key.source, itemID: key.itemID, revision: key.revision)
  }

  /// The home card key for an artwork identity. The warm pass and every card surface build their
  /// key here, so the variant and width can never disagree.
  static func cardKey(
    source: ArtworkSource, itemID: String, revision: ArtworkRevision
  ) -> ArtworkKey {
    ArtworkKey(
      source: source, itemID: itemID, variant: .homeCard(pixelWidth: cardPixelWidth),
      revision: revision)
  }

  /// Whether `displayed` carries at least as much of the cover as `card`, so its bytes give the
  /// card's answer.
  nonisolated static func canStandIn(_ displayed: ArtworkKey, for card: ArtworkKey) -> Bool {
    displayed.variant.pixelWidth >= card.variant.pixelWidth
  }
}

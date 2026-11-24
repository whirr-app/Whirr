import ABSApi
import DesignSystem
import Foundation

/// Home's view of `CoverPaletteService`: washes by item for the screens that paint editorial cards.
/// A card names its item, revision and, for a feed, its artwork source; everything about its colour
/// is the service's. Card requests are coverable, so they park while the shell is covered.
extension CoverPaletteService {
  /// The identity a card's colour answers for. A card with no source of its own is the account's.
  func cardIdentity(
    itemID: String, revision: ArtworkRevision, source: ArtworkSource?
  ) -> CoverPaletteIdentity {
    CoverPaletteIdentity(
      accountScope: (source ?? .audiobookshelf(accountScope)).cacheScope, itemID: itemID,
      revision: revision)
  }

  /// Memory only, so a view can ask from inside the update that first draws its cards.
  func memoryCachedWashes(
    itemIDs: [String],
    revisionsByID: [String: ArtworkRevision],
    sourcesByID: [String: ArtworkSource] = [:]
  ) -> [String: CoverWash] {
    var result: [String: CoverWash] = [:]
    for itemID in Self.unique(itemIDs) {
      let identity = cardIdentity(
        itemID: itemID, revision: revisionsByID[itemID] ?? .unversioned, source: sourcesByID[itemID])
      if let palette = palette(for: identity) {
        result[itemID] = Self.wash(from: palette)
      }
    }
    return result
  }

  /// Memory, then the saved rows in one read; never bytes or extraction. A miss is absent, left to
  /// the ordinary `resolveWashes` path.
  func cachedWashes(
    itemIDs: [String],
    revisionsByID: [String: ArtworkRevision],
    sourcesByID: [String: ArtworkSource] = [:]
  ) async -> [String: CoverWash] {
    let identities = Self.unique(itemIDs).map {
      cardIdentity(itemID: $0, revision: revisionsByID[$0] ?? .unversioned, source: sourcesByID[$0])
    }
    let palettes = await cachedPalettes(identities)
    return Dictionary(
      palettes.map { ($0.key.itemID, Self.wash(from: $0.value)) }, uniquingKeysWith: { first, _ in first })
  }

  /// Resolves cards as one result dictionary. A cover that is cold or fails is absent, so the card
  /// stays neutral rather than caching a transient miss; the service follows its row.
  func resolveWashes(
    itemIDs: [String],
    displaySize: CGFloat,
    displayScale: CGFloat,
    artworkRole: CoverImageView.Role = .homeCard,
    intent: HomeWashProvider.RequestIntent = .visible,
    revisionsByID: [String: ArtworkRevision],
    sourcesByID: [String: ArtworkSource] = [:]
  ) async -> [String: CoverWash] {
    let requests = Self.unique(itemIDs).map { itemID in
      let source = sourcesByID[itemID] ?? .audiobookshelf(accountScope)
      let revision = revisionsByID[itemID] ?? .unversioned
      let key = Self.cardArtworkKey(
        source: source, itemID: itemID, displaySize: displaySize, displayScale: displayScale,
        role: artworkRole, revision: revision)
      return CoverPaletteRequest(
        identity: cardIdentity(itemID: itemID, revision: revision, source: source),
        bytes: artwork?.bytes(displayed: key) ?? CoverBytes(cached: { nil }, awaitArrival: {}),
        requestClass: intent == .visible ? .visible : .background,
        isCoverable: true)
    }
    guard requests.isEmpty == false else { return [:] }
    let palettes = await request(requests)
    return Dictionary(
      palettes.map { ($0.key.itemID, Self.wash(from: $0.value)) }, uniquingKeysWith: { first, _ in first })
  }

  /// A card paints the palette's accent, as the row's accent columns record it.
  static func wash(from palette: CoverPalette) -> CoverWash {
    let accent = palette.rawAccentHSB
    return CoverWash.from(
      hue: accent?.hue, saturation: accent?.saturation, brightness: accent?.brightness)
  }

  private static func cardArtworkKey(
    source: ArtworkSource,
    itemID: String,
    displaySize: CGFloat,
    displayScale: CGFloat,
    role: CoverImageView.Role,
    revision: ArtworkRevision
  ) -> ArtworkKey {
    let variant: ArtworkVariant =
      switch role {
      case .libraryThumbnail:
        .libraryThumbnail(displaySize: Double(displaySize), displayScale: Double(displayScale))
      case .homeCard:
        .homeCard(displaySize: Double(displaySize), displayScale: Double(displayScale))
      case .highFidelity:
        .highFidelity(displaySize: Double(displaySize), displayScale: Double(displayScale))
      case .detail:
        DetailArtwork.variant(
          itemID: itemID, revision: revision, displayScale: Double(displayScale))
      }
    return ArtworkKey(source: source, itemID: itemID, variant: variant, revision: revision)
  }

  private static func unique(_ itemIDs: [String]) -> [String] {
    var seen = Set<String>()
    return itemIDs.filter { seen.insert($0).inserted }
  }
}

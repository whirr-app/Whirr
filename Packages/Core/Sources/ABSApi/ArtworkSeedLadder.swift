/// Computes the smaller artwork keys that can seed a cover while it loads.
public enum ArtworkSeedLadder {
  /// Returns smaller candidates from the largest available pixel width down. Candidates with the
  /// same pixel width have byte-identical requests, so the first in caller order is kept.
  ///
  /// Every variant is seeded, not just `.highFidelity`: the byte cache is keyed by full URL
  /// including `width=`, so a width no other surface uses is a guaranteed local miss, and offline
  /// the surface would paint generated art.
  public static func candidates(
    for key: ArtworkKey,
    seedVariants: [ArtworkVariant]
  ) -> [ArtworkKey] {
    let pixelWidth = key.variant.pixelWidth

    var variantsByWidth: [Int: ArtworkVariant] = [:]
    for variant in seedVariants where variant.pixelWidth < pixelWidth {
      if variantsByWidth[variant.pixelWidth] == nil {
        variantsByWidth[variant.pixelWidth] = variant
      }
    }

    return variantsByWidth.values
      .sorted { $0.pixelWidth > $1.pixelWidth }
      .map {
        ArtworkKey(
          source: key.source,
          itemID: key.itemID,
          variant: $0,
          revision: key.revision)
      }
  }
}

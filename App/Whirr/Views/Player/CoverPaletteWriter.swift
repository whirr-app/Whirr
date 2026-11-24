import ABSApi
import DesignSystem
import Foundation
import Persistence

/// The rules every writer of a saved palette follows: which row answers for a cover, which bytes
/// its colour is extracted from, how many extractions run at once, and what a row records.
/// `CoverPaletteService` is the only writer and applies them, so surfaces agree on what a row is.
enum CoverPaletteWriter {
  /// What a request may do to obtain cover bytes. Neither class opens a transfer of its own:
  /// palette work never spends a cover permit (`CoverPaletteService.CoverBytes`).
  nonisolated enum RequestClass: Sendable, Equatable {
    /// A surface drawing the cover. It may join the display fetch already running for its
    /// displayed key, when that key can stand in for the card (`CoverPaletteSource`).
    case visible
    /// Backfill and warming. Cached bytes only.
    case background

    var priority: ArtworkPriority { self == .visible ? .visible : .scrollPrefetch }
  }

  /// Production's one extraction admission, shared by every writer: one Core Image pass at a time,
  /// visible requests ahead of background ones. Tests inject their own so a held extraction in
  /// one test cannot stall another.
  static let sharedAdmission = CoverDecodeAdmission(maximumConcurrent: 1)

  /// The key every writer files a palette under, variant-free: detail analyses a high-fidelity
  /// JPEG, Home a small one, and the first to arrive decides both. All writers must agree on the
  /// string or sharing silently stops. `nonisolated` for `Sendable` identities off the main actor.
  /// Changing `extractionStamp` strands older rows, so covers re-derive with no migration.
  nonisolated static func recordIdentity(
    accountScope: ArtworkAccountScope, itemID: String, revision: ArtworkRevision
  ) -> String {
    "\(accountScope.rawValue)|\(itemID)|\(revision.rawValue)|\(extractionStamp)"
  }

  /// K-means without `perceptual` on a Lanczos-reduced cover (see `CoverPaletteExtractor`), picked
  /// by relative chroma (see `CoverAccentSelection`), with `AudibleSash` masked.
  nonisolated static let extractionStamp = "srgb-kmeans-relative-sash-lanczos"

  nonisolated static func recordIdentity(for key: ArtworkKey) -> String {
    recordIdentity(accountScope: key.accountScope, itemID: key.itemID, revision: key.revision)
  }

  /// Whether `record` is the complete answer for `identity`: written for this cover by the current
  /// extraction, and carrying the page evidence every surface needs. A row without that evidence
  /// predates those columns and must be rejected by cards as well as the player.
  nonisolated static func answers(_ record: CoverPaletteRecord?, for identity: String) -> Bool {
    guard let record else { return false }
    return record.artworkKey == identity && record.carriesPageEvidence
  }

  /// The cached palette-source bytes for a surface displaying `displayed`: the home card's, else
  /// the displayed cover's when it can stand in for the card. `nil` means nothing usable is on
  /// disk yet.
  static func cachedSourceBytes(
    displayed: ArtworkKey, read: @Sendable (ArtworkKey) async -> Data?
  ) async -> Data? {
    let card = CoverPaletteSource.cardKey(for: displayed)
    if let data = await read(card) { return data }
    guard CoverPaletteSource.canStandIn(displayed, for: card) else { return nil }
    return await read(displayed)
  }

  /// Whether a request of `requestClass` displaying `displayed` may wait for that cover's display
  /// fetch when nothing is cached.
  static func mayJoinDisplayFetch(_ displayed: ArtworkKey, requestClass: RequestClass) -> Bool {
    requestClass == .visible
      && CoverPaletteSource.canStandIn(displayed, for: CoverPaletteSource.cardKey(for: displayed))
  }

  /// Extracts `data` under `admission`, ahead of or behind other writers by `requestClass`.
  /// `nil` when the extraction yields nothing or the caller is cancelled while queued.
  static func samples(
    from data: Data,
    requestClass: RequestClass,
    admission: CoverDecodeAdmission,
    extract: @Sendable (Data) async -> CoverPaletteSamples?
  ) async -> CoverPaletteSamples? {
    let priority = requestClass.priority
    do {
      try await admission.acquire(priority: priority)
    } catch {
      return nil
    }
    guard Task.isCancelled == false else {
      await admission.release(priority: priority)
      return nil
    }
    let samples = await extract(data)
    await admission.release(priority: priority)
    return samples
  }

  /// The row every writer saves for `palette`: the accent a card washes with and the page evidence
  /// the player and detail pages rebuild from, so any surface can answer from any other's write.
  static func record(
    itemID: String, identity: String, palette: CoverPalette, extractedAt: Date = Date()
  ) -> CoverPaletteRecord {
    let accent = palette.rawAccentHSB
    let evidence = palette.ambientAppearance.evidence
    return CoverPaletteRecord(
      itemId: itemID,
      artworkKey: identity,
      accentHue: accent?.hue,
      accentSaturation: accent?.saturation,
      accentBrightness: accent?.brightness,
      clusterWeight: evidence.clusterWeight,
      clusterRed: evidence.cluster?.red,
      clusterGreen: evidence.cluster?.green,
      clusterBlue: evidence.cluster?.blue,
      averageRed: evidence.average.red,
      averageGreen: evidence.average.green,
      averageBlue: evidence.average.blue,
      extractedAt: extractedAt)
  }

  /// The page a row rebuilds. A row carrying page evidence rebuilds the identical page. A nil
  /// accent is still an answer, because a grey cover legitimately has none.
  static func palette(from record: CoverPaletteRecord) -> CoverPalette? {
    guard let averageRed = record.averageRed, let averageGreen = record.averageGreen,
      let averageBlue = record.averageBlue
    else { return nil }
    var cluster: WhirrRGBColor?
    if let red = record.clusterRed, let green = record.clusterGreen, let blue = record.clusterBlue {
      cluster = WhirrRGBColor(red, green, blue)
    }
    var accent: CoverAccentHSB?
    if let hue = record.accentHue, let saturation = record.accentSaturation,
      let brightness = record.accentBrightness
    {
      accent = CoverAccentHSB(hue: hue, saturation: saturation, brightness: brightness)
    }
    return CoverAmbientPalette.palette(
      fromEvidence: CoverPageEvidence(
        average: WhirrRGBColor(averageRed, averageGreen, averageBlue), cluster: cluster,
        clusterWeight: record.clusterWeight ?? 0),
      accent: accent)
  }
}

import Persistence

/// The episode the analysis worker is on, for the transient tile glyph.
public struct AdSkipAnalysisActivity: Equatable, Sendable {
  /// The analysed identity and the identities linked to it: an RSS episode lists its server copy,
  /// which a tile may show instead.
  public var identities: Set<AdSkipEpisodeIdentity>

  public init(identities: Set<AdSkipEpisodeIdentity>) {
    self.identities = identities
  }

  /// Item and episode only, ignoring the account as the player's range lookup does. Two accounts'
  /// copies of one server episode are both marked, which is harmless for a glyph.
  public func includes(itemID: String, episodeID: String) -> Bool {
    identities.contains { $0.itemID == itemID && $0.episodeID == episodeID }
  }
}

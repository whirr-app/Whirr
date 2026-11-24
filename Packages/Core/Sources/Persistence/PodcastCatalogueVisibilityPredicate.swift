/// The catalogue visibility rule for podcast containers created or hydrated from the server. An
/// exact zero is the only authoritative empty state; an absent, negative or positive episode count
/// stays visible (unknown/corrupt, or content-bearing).
///
/// Catalogue/discovery projections only. Not for refresh candidate selection, destination
/// resolution, item detail, activity, storage, player or history queries: an empty server
/// container remains a valid reusable target.
enum PodcastCatalogueVisibilityPredicate {
  /// SQL expression for queries whose item table is named `item` (including the GRDB query
  /// interface's default table name). SQLite's `<>` comparison lets negative counts
  /// fail open while `IS NULL` keeps unknown counts visible.
  static let sql = """
    (
      item.mediaKind <> 'podcast'
      OR item.podcastServerEpisodeCount IS NULL
      OR item.podcastServerEpisodeCount <> 0
    )
    """

  /// The pure counterpart used by persistence tests and non-SQL projection checks.
  static func matches(mediaKind: String, podcastServerEpisodeCount: Int?) -> Bool {
    mediaKind != "podcast" || podcastServerEpisodeCount == nil || podcastServerEpisodeCount != 0
  }
}

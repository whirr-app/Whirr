import Persistence

/// The text and bar decisions every Home item surface shares: the shelf card
/// (`HomeViewPresentation.card`) and the more-screen row (`HomeMoreItemRowPresentation`). Each
/// surface keeps its own captions and layout; deriving these four facts once is what keeps a title
/// from reading one way on Home and another a tap away.
public struct HomeCardText: Sendable, Equatable {
  public let title: String
  /// `nil` rather than "" when there is no second line, so a surface can omit it.
  public let subtitle: String?
  /// What the badge names. A reading surface badges the item as an ebook even when it also has
  /// audio, because the progress beside it is reading progress.
  public let badgeCategory: ItemMediaCategory
  /// `nil` on a surface without progress, and for a finished item: marking a title done leaves its
  /// stored position where the listener left it, so the fraction alone still reads as part-played,
  /// and a bar frozen there contradicts the finished mark beside it.
  public let progressFraction: Double?

  /// A progress-bearing podcast row with an episode presents the episode first and its show second;
  /// anywhere else the row is the item itself and its author.
  ///
  /// `progressSeconds` is the position the card prints, resolved through
  /// `PlaybackModel.displayedPositionSeconds` so the playing title reads live. Defaults to the
  /// persisted position; reading progress ignores it.
  public init(
    item: HomeItem, showsProgress: Bool, usesEbookProgress: Bool = false,
    progressSeconds: Double? = nil
  ) {
    let presentsEpisode = showsProgress && item.category == .podcast && item.episodeID != nil
    title = presentsEpisode ? (item.episodeTitle ?? PodcastCopy.untitledEpisode) : item.title
    let secondLine = presentsEpisode ? item.title : item.author
    subtitle = (secondLine?.isEmpty == false) ? secondLine : nil
    badgeCategory = usesEbookProgress ? .ebook : item.category

    let fraction =
      usesEbookProgress
      ? HomeRowPresentation.ebookProgressFraction(ebookProgress: item.ebookProgress)
      : HomeRowPresentation.progressFraction(
        progressSeconds: progressSeconds ?? item.progressSeconds,
        durationSeconds: item.durationSeconds)
    progressFraction = showsProgress && item.isFinished == false ? fraction : nil
  }
}

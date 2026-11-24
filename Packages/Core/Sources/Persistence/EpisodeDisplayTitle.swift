/// The two display lines for a podcast episode: the episode's own title over the show's title.
///
/// One value so every surface that names an episode agrees. The lock screen and CarPlay draw the
/// primary line as the title and the secondary as the subtitle; the bookmark row projects the same
/// pair as `title`/`author`. Deriving either line separately is how the two copies drifted apart.
///
/// A non-episode item (an audiobook) keeps its own title and author and never uses this value.
public struct EpisodeDisplayTitle: Sendable, Equatable {
  /// The episode's own title, or the show's title when the episode carries none. A blank title is
  /// absent, not a title worth drawing.
  public let primary: String
  /// The show's title: the item that owns the episode.
  public let secondary: String

  public init(episodeTitle: String?, showTitle: String) {
    self.primary = episodeTitle.flatMap { $0.isEmpty ? nil : $0 } ?? showTitle
    self.secondary = showTitle
  }
}

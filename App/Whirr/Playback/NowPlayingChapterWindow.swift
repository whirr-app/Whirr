import PlayerCore

/// The window the lock screen's Now Playing timeline covers.
///
/// A 20-hour audiobook as one span makes the lock-screen scrubber useless, so a chaptered
/// audiobook publishes duration and elapsed scoped to the current chapter.
/// `NowPlayingMetadataAdapter` publishes chapter-relative time and `RemoteCommandAdapter` maps
/// scrubs back to the global timeline; both must use this window. Nil (whole item) for a podcast
/// episode, a book with no chapters, or a gap between chapters.
enum NowPlayingChapterWindow {
  static func chapter(for state: PlayerState) -> PlaybackChapter? {
    state.chapterWindow
  }
}

import AppModel
import DesignSystem
import Persistence
import Testing

@testable import Whirr

/// The Library funnel shows a glyph on every media row, unlike the app's other menus. These tests
/// pin where the media glyphs come from, and which rows have none.
struct BrowseFilterMenuPresentationTests {
  /// `MediaKindBadge.symbolName` reserves the media-kind glyph: surfaces that picture a kind "must
  /// not be free to pick a different one". The funnel is such a surface. Its rows are badged with
  /// these glyphs directly behind the open menu, so a hand-spelled name would look wrong.
  @Test("a media row's glyph is the glyph its library rows are badged with")
  func mediaGlyphsMatchTheRowBadge() {
    #expect(
      BrowseFilterMenuPresentation.mediaSymbolName(for: .audiobooks)
        == MediaKindBadge.audiobook.symbolName)
    #expect(
      BrowseFilterMenuPresentation.mediaSymbolName(for: .podcasts)
        == MediaKindBadge.podcast.symbolName)
    #expect(
      BrowseFilterMenuPresentation.mediaSymbolName(for: .ebooks) == MediaKindBadge.ebook.symbolName)
  }

  /// `.all` is not drawn as a row. "No kind selected" is All, so it has nothing to picture, and the
  /// view falls back to a plain title rather than an empty symbol name.
  @Test("the absent All row has no glyph to draw")
  func allHasNoGlyph() {
    #expect(MediaFilter.all.category == nil)
    #expect(BrowseFilterMenuPresentation.mediaSymbolName(for: .all) == nil)
  }

  /// Every media kind the funnel offers resolves, so a fourth kind cannot arrive glyphless.
  @Test("every drawn media row resolves a glyph")
  func everyDrawnMediaRowResolvesAGlyph() {
    for filter in MediaFilter.allCases where filter.category != nil {
      #expect(
        BrowseFilterMenuPresentation.mediaSymbolName(for: filter) != nil,
        "no glyph for \(filter)")
    }
  }

  /// The same glyph every download command in the app draws, rather than a funnel-only variant.
  @Test("Downloaded reuses the app's download glyph")
  func downloadedReusesTheDownloadGlyph() {
    #expect(
      BrowseFilterMenuPresentation.downloadedSymbolName
        == PodcastShowViewPresentation.contextAction(.download, creator: nil)?.systemImage)
  }

  /// The playback dimension has no glyphs. There is no honest picture of "Any", and Files' sort
  /// picker has none for the same reason. `BrowseFilterMenuPresentation` offers no playback symbol.
  @Test("the playback rows are named, not pictured")
  func playbackRowsAreNamedNotPictured() {
    for playback in PlaybackFilter.allCases {
      #expect(LibraryFilterCopy.playbackLabel(for: playback).isEmpty == false)
    }
  }
}

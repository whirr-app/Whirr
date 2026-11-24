import Foundation
import Testing

@testable import Whirr

/// Views reach the playhead only through `PlaybackModel.displayedPositionSeconds` (players) or
/// `listPositionSeconds` (rows, cards, captions; about once a minute), called from the view that
/// prints it. The resolvers read the playhead only for the loaded identity, so other rows stay
/// independent of it. A view reading `playback.currentTime` or `displayedItemPositionSeconds`
/// skips that guard, and in a list's parent body the whole list depends on the playhead. It
/// still compiles, so the rule is pinned against the source. The ban on direct reads is
/// `views-read-playhead-through-resolver` in `Scripts/source-rules/player.toml`; the scans below
/// compare rows with lists, which a text rule cannot express.
@Suite("Playback position reads")
struct PlaybackPositionReadsSourceTests {
  private static let resolverCalls = ["displayedPositionSeconds(", "listPositionSeconds("]

  /// Row surfaces that read through the resolver. Each must keep resolving, or its playing row
  /// goes back to showing the last save.
  private static let resolvingRowSources = [
    "PodcastShowContentView.swift",
    "WideCompactCard.swift",
    "HomeItemShelfCard.swift",
    "HomePodcastEpisodeShelfCard.swift",
    "HomeSavedShelfCard.swift",
    "HomeMoreView.swift",
    "AuthorSeriesGridTile.swift",
    "PodcastEpisodeCardView.swift",
    "ItemDetailPlayButtonPresentation.swift",
  ]

  @Test("every progress-bearing row resolves its position")
  func everyProgressBearingRowResolvesItsPosition() throws {
    // `DisplayedPositionReader` is the resolver called one view down. The card installs a context
    // menu, so it must not read the playhead in its own body.
    let resolving = Set(
      try ViewSourceScan.sourcesContaining([
        "listPositionSeconds(", "DisplayedPositionReader(",
      ]))

    for source in Self.resolvingRowSources {
      #expect(resolving.contains(source), "\(source) no longer resolves its displayed position")
    }
  }

  /// Progress bars and remaining-time captions move to the minute, so they follow the playhead at
  /// list cadence. The per-tick resolver would put the row body back on the two-per-second tick,
  /// which rebuilt each playing card on Home at about 12 ms each time.
  @Test("progress-bearing rows resolve at list cadence, not per tick")
  func progressBearingRowsResolveAtListCadence() throws {
    let perTick = Set(try ViewSourceScan.sourcesContaining(["playback.displayedPositionSeconds("]))
    let offenders = Self.resolvingRowSources.filter { perTick.contains($0) }
    #expect(offenders.isEmpty, "\(offenders.joined(separator: ", ")) reads the per-tick playhead")
    #expect(
      try ViewSourceScan.executableText(ofViewNamed: "DisplayedPositionReader")
        .contains("playback.listPositionSeconds("))
  }

  /// The show page's parent body resolves the list and must not follow the playhead; its row does.
  @Test("the show page resolves position in its row, not its list")
  func theShowPageResolvesPositionInItsRow() throws {
    let text = try ViewSourceScan.executableText(ofViewNamed: "PodcastShowContentView")
    let rowStart = try #require(text.range(of: "private struct PodcastShowEpisodeRow"))

    #expect(
      ViewSourceScan.occurrences(
        of: Self.resolverCalls, in: String(text[..<rowStart.lowerBound])) == 0)
    #expect(
      ViewSourceScan.occurrences(
        of: Self.resolverCalls, in: String(text[rowStart.lowerBound...])) > 0)
  }
}

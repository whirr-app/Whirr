import ABSApi
import AppModel
import DesignSystem
import Foundation
import Persistence
import Testing

@testable import Whirr

/// While playing, `PlaybackModel.displayedPositionSeconds` changes about twice a second and
/// `listPositionSeconds` about once a minute, and a body reading either re-runs at that rate. A
/// menu built in the same body (`Menu`, `.contextMenu`, `itemContextMenu`) is rebuilt while open,
/// pulsing its glass. So the read belongs in a leaf below the menu, or the menu behind an
/// `.equatable()` boundary above it.
@Suite("Menus are isolated from the playhead")
struct MenuPlayheadIsolationTests {
  /// Views that read the position in a lazily evaluated child closure, not their own body.
  /// `HomeMoreView.liveProgress` runs inside `WideCompactCard`'s `trailingContent`, which that card
  /// calls from its own body. A tick redraws the card, not the row that carries the menu.
  private static let lazilyReadingViews: Set<String> = ["HomeMoreView"]

  /// A source-level check, because the rendered view tree is not a stable value to assert on. It
  /// reads one type at a time (declaration plus extensions) and cannot see across a call into a
  /// child view that receives the position as a plain value. The show page's episode row is that
  /// case, and it is covered by the DesignSystem row's own equatable menu leaves and the test
  /// below.
  @Test("no view reads the playhead in the same type that builds a menu")
  func noViewReadsThePlayheadBesideAMenu() throws {
    let declaration = try Regex(
      #"^(?:(?:private|fileprivate|public|internal|nonisolated|@MainActor)\s+)*(?:struct|enum|extension|class|final class|actor)\s+([A-Za-z_][A-Za-z0-9_]*)"#
    )
    let menuMarker = try Regex(#"(\.contextMenu\b|ContextMenu\w*\(|\bMenu\s*[({])"#)

    var offenders: [String] = []
    for source in try ViewSourceScan.sources() {
      var types: [String: [Substring]] = [:]
      var current: String?
      for line in try ViewSourceScan.executableText(of: source).split(
        separator: "\n", omittingEmptySubsequences: false)
      {
        if let match = line.firstMatch(of: declaration), let name = match.output[1].substring {
          current = String(name)
        }
        if let current { types[current, default: []].append(line) }
      }
      for (name, lines) in types where Self.lazilyReadingViews.contains(name) == false {
        let text = lines.joined(separator: "\n")
        let readsPlayhead =
          text.contains("displayedPositionSeconds(") || text.contains("listPositionSeconds(")
        if readsPlayhead, text.contains(menuMarker) {
          offenders.append("\(source.lastPathComponent): \(name)")
        }
      }
    }
    #expect(offenders.sorted() == [])
  }

  /// The show page's row prints the live position, so it re-renders on every tick. Its menus are
  /// compared on the action sections, which is the invariant that makes that comparison hold.
  @Test("a position tick moves the show row's caption but not its menu sections")
  func showRowMenuSectionsIgnoreThePlayhead() {
    let summary = PodcastEpisodeSummary(
      id: "episode", title: "Episode", subtitle: "Subtitle", episodeDescription: nil,
      seasonNumber: nil, episodeNumber: nil, episodeType: nil, durationSeconds: 3_600,
      sizeBytes: 10, publishedAt: Date(timeIntervalSince1970: 0), progressSeconds: 60,
      isPlayed: false, isFinished: false, downloadStatus: .completed,
      isAvailableOnServer: true)
    let earlier = PodcastShowViewPresentation.episode(
      summary, progressSeconds: 420, queueAvailability: .both, isCurrentlyPlaying: true)
    let later = PodcastShowViewPresentation.episode(
      summary, progressSeconds: 1_500, queueAvailability: .both, isCurrentlyPlaying: true)

    #expect(earlier.progressText != later.progressText)
    #expect(earlier.actionSections == later.actionSections)
  }

  /// The DesignSystem row draws both menus through its equatable leaves, so the comparison above
  /// decides whether a presented menu is rebuilt.
  @Test("the episode row builds both menus behind an equatable boundary")
  func episodeRowMenusAreEquatable() throws {
    let row = ViewSourceScan.repositoryRoot().appending(
      path: "Packages/Core/Sources/DesignSystem/Components/PodcastEpisodeRowView.swift")
    let text = try ViewSourceScan.executableText(of: row)
    #expect(text.contains("MediaActionMenuItems(") && text.contains("PodcastEpisodeRowActionMenu("))
    #expect(ViewSourceScan.occurrences(of: [".equatable()"], in: text) == 2)
  }
}

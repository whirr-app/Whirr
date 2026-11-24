import AppModel
import Foundation
import Persistence
import Testing

@testable import Whirr

/// The Podcasts tab's Latest Episodes shelf and its drill-down list the same episode row. Which
/// gestures it answers belongs to the episode, not the screen, but nothing enforces that: the
/// drill-down once answered no swipe while the shelf answered five. Row, chrome, wash and cover
/// metric come from `WideCompactCard`'s episode flavour; each list must still apply the gesture
/// vocabulary, which this suite checks in the source.
@Suite("Podcast episode row parity")
struct PodcastEpisodeRowParityTests {
  /// Matches the call as swift-format lays it out.
  private static let episodeRow = "WideCompactCard(\n      episode:"

  /// Each episode row needs these treatments. Each names the shared entry point that supplies it,
  /// and the references one row needs.
  private static let sharedTreatments: [(name: String, markers: [String], perRow: Int)] = [
    ("swipe actions", ["podcastEpisodeSwipeActions("], 1),
    ("long-press menu", ["itemContextMenu("], 1),
  ]

  /// The one list that does not inherit the latest-episode swipe.
  ///
  /// Saved for Later uses `ItemSwipeActions`' vocabulary: Remove from Saved outermost on the
  /// trailing edge, no progress action. Other treatments stay shared, and this file must not
  /// resolve the episode vocabulary itself. Both vocabularies keep an episode's device action on
  /// the trailing edge.
  private static let swipeExceptions: [String: String] = [
    "SavedForLaterView.swift": "ItemSwipeActions.actions("
  ]

  /// The one layout that lists the episode row without the latest-episode swipe, keyed by file and
  /// by the function that composes it.
  ///
  /// On a wide iPad, Latest Episodes sets two cards per row and a swipe would reveal across the
  /// row, not under either card, so neither swipes. The pair keeps the long-press menu, fine only
  /// because it offers every swipe action (checked below). Single column still swipes.
  private static let swipeFreeLayouts: [String: String] = [
    "PodcastsView+LatestEpisodes.swift": "latestEpisodePairRow("
  ]

  @Test("every episode list gives its rows the same shared treatments")
  func everyEpisodeListAppliesTheSharedTreatments() throws {
    var violations: [String] = []

    for source in try ViewSourceScan.sources() {
      let text = try ViewSourceScan.executableText(of: source)
      let rows = ViewSourceScan.occurrences(of: [Self.episodeRow], in: text)
      guard rows > 0 else { continue }
      let isSwipeException = Self.swipeExceptions[source.lastPathComponent] != nil

      for treatment in Self.sharedTreatments {
        if isSwipeException, treatment.name == "swipe actions" { continue }
        let applications = ViewSourceScan.occurrences(of: treatment.markers, in: text)
        let required = rows * treatment.perRow
        if applications < required {
          violations.append(
            "\(source.lastPathComponent): \(rows) episode row(s) need \(required) \(treatment.name) reference(s), found \(applications)"
          )
        }
      }
    }

    #expect(
      violations.isEmpty,
      "An episode list must give its rows every treatment the other episode list gives them. Offenders: \(violations.joined(separator: "; "))"
    )
  }

  /// The lists this suite keeps level. Adding one needs the shared treatments in hand, or a
  /// stated reason in `swipeExceptions`.
  @Test("the scan still covers every episode list")
  func scanCoversEveryEpisodeList() throws {
    let files = try ViewSourceScan.sourcesContaining([Self.episodeRow])

    #expect(
      files == ["HomeMoreView.swift", "PodcastEpisodeListRow.swift", "SavedForLaterView.swift"])
    #expect(Self.swipeExceptions.keys.allSatisfy(files.contains))
  }

  /// Both lists resolve their buttons through the one function that
  /// `PodcastEpisodeSwipeActionsModifier` calls. The vocabulary each row offers is pinned once, in
  /// the presentation tests, not per screen.
  @Test("the shared modifier is the only place a latest-episode swipe is resolved or executed")
  func swipeResolutionAndExecutionLiveInOnePlace() throws {
    var offenders: [String] = []

    for source in try ViewSourceScan.sources()
    where source.lastPathComponent != "PodcastEpisodeSwipeActionsModifier.swift" {
      let text = try ViewSourceScan.executableText(of: source)
      guard ViewSourceScan.occurrences(of: [Self.episodeRow], in: text) > 0 else { continue }

      // A declared exception may render its own buttons, but must not resolve the episode
      // vocabulary, which would be a second copy of the rule. It must name its policy instead.
      if let policy = Self.swipeExceptions[source.lastPathComponent] {
        if text.contains("PodcastsViewPresentation.swipeButtons(") {
          offenders.append("\(source.lastPathComponent): PodcastsViewPresentation.swipeButtons(")
        }
        if text.contains(policy) == false {
          offenders.append("\(source.lastPathComponent): no \(policy)")
        }
        continue
      }

      for marker in ["PodcastsViewPresentation.swipeButtons(", "podcastEpisodeSwipeButtons("]
      where text.contains(marker) {
        offenders.append("\(source.lastPathComponent): \(marker)")
      }
    }

    #expect(
      offenders.isEmpty,
      "An episode list must take its swipe actions from the shared modifier rather than wiring its own. Offenders: \(offenders.joined(separator: ", "))"
    )
  }

  @Test("a declared swipe-free layout applies the menu and no swipe")
  func swipeFreeLayoutsAreDeclaredAndMenuOnly() throws {
    for (fileName, function) in Self.swipeFreeLayouts {
      let source = try #require(ViewSourceScan.sources().first { $0.lastPathComponent == fileName })
      let text = try ViewSourceScan.executableText(of: source)
      let start = try #require(
        text.range(of: "private func \(function)"), "\(fileName) no longer declares \(function)")
      let rest = text[start.upperBound...]
      let body = rest[..<(rest.range(of: "private func ")?.lowerBound ?? rest.endIndex)]

      #expect(body.contains("podcastEpisodeSwipeActions(") == false)
      // The menu comes through the card helper both layouts share, which applies `itemContextMenu`.
      #expect(body.contains("latestEpisodeCardWithMenu("))
    }
  }

  @Test("a swipe-free layout loses no action the swipe offered")
  func aSwipeFreeLayoutLosesNoActionTheSwipeOffered() {
    let itemID = "show-1"
    let episodeID = "episode-1"
    let identity = ListeningQueueActionPolicy.identity(
      itemID: itemID, episodeID: episodeID, category: .podcast)
    let elsewhere = ListeningQueueActionPolicy.identity(
      itemID: "show-2", episodeID: "episode-2", category: .podcast)
    let deviceActions: [ItemContextMenuDownloadAction] = [.download, .remove, .unavailable]
    let playbackStatuses: [ItemPlaybackStatus?] = [nil, .inProgress, .finished]

    for deviceAction in deviceActions {
      for playbackStatus in playbackStatuses {
        for nowPlaying in [nil, identity, elsewhere] {
          let swipe = PodcastEpisodeSwipeActions.actions(
            deviceAction: deviceAction, isAvailableOnServer: true,
            playbackStatus: playbackStatus, identity: identity, nowPlaying: nowPlaying,
            isPlaybackIntended: nowPlaying != nil && nowPlaying == identity)
          // The menu's inputs, derived for this row the way `ItemContextMenuContent` derives them.
          let menu = ItemContextMenuPresentation.podcastEpisodeEntries(
            downloadAction: deviceAction,
            surface: .episodeList,
            queueAvailability: ListeningQueueActionPolicy.availability(
              itemID: itemID, episodeID: episodeID, category: .podcast, nowPlaying: nowPlaying),
            playbackStatus: playbackStatus,
            isCurrentlyPlaying: nowPlaying != nil && nowPlaying == identity)
          let missing = Set(swipe.leading + swipe.trailing).subtracting(menu)

          #expect(
            missing.isEmpty,
            "\(deviceAction), \(String(describing: playbackStatus)), now playing \(String(describing: nowPlaying)): menu lacks \(missing)"
          )
        }
      }
    }
  }
}

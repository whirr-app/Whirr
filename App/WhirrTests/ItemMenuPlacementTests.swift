import AppModel
import Foundation
import Testing

@testable import Whirr

/// Ties every shared-menu call site to the declared `PodcastMenuBearingSurface` inventory, so the
/// inventory is the one rule for which suppression context a menu raises in.
///
/// `.card` and `.episodeList` suppress the same entries today, so a call site on the wrong surface
/// shows nothing on a device; Home's Continue Listening card once sat on the wrong one unnoticed.
@Suite("Item menu placement")
struct ItemMenuPlacementTests {

  // MARK: - Inventory mapping

  /// Spelled out case by case rather than re-deriving the switch, so a remapped case is a
  /// deliberate edit in two places.
  private static let expectedMenuSurface: [PodcastMenuBearingSurface: PodcastMenuSurface] = [
    .homeItemCard: .card,
    .homeEpisodeCard: .card,
    .homeMoreRow: .episodeList,
    .libraryBrowseRow: .episodeList,
    .searchResultRow: .episodeList,
    .podcastShowEpisodeRow: .show,
    .podcastsTabContinueListeningCard: .card,
    .podcastsTabLatestEpisodeRow: .episodeList,
    .smartListEpisodeRow: .episodeList,
    .podcastsTabShowTile: .card,
    .podcastAllShowsPageTile: .card,
    .downloadsRow: .episodeList,
    .savedForLaterRow: .episodeList,
    .itemDetail: .episodeList,
  ]

  /// `.homeItemCard` is here because Home's Continue Listening draws its episodes on that card.
  private static let expectedEpisodeSurfaces: Set<PodcastMenuBearingSurface> = [
    .homeItemCard, .homeEpisodeCard, .homeMoreRow, .searchResultRow, .podcastShowEpisodeRow,
    .podcastsTabContinueListeningCard, .podcastsTabLatestEpisodeRow, .smartListEpisodeRow,
    .downloadsRow, .savedForLaterRow,
  ]

  @Test("the expectation table covers every inventory case")
  func expectationsCoverTheInventory() {
    #expect(Set(Self.expectedMenuSurface.keys) == Set(PodcastMenuBearingSurface.allCases))
  }

  @Test(arguments: PodcastMenuBearingSurface.allCases)
  func inventoryCaseRaisesItsMenuOnTheIntendedSurface(placement: PodcastMenuBearingSurface) {
    #expect(placement.menuSurface == Self.expectedMenuSurface[placement])
  }

  @Test(arguments: PodcastMenuBearingSurface.allCases)
  func inventoryCaseDeclaresWhetherItCarriesAnEpisode(placement: PodcastMenuBearingSurface) {
    #expect(placement.isEpisodeSurface == Self.expectedEpisodeSurfaces.contains(placement))
  }

  // MARK: - Call sites

  private static let menuCallMarkers = ["itemContextMenu(", "ItemContextMenuContent("]

  /// The inventory case each shared-menu call site states, by file, in source order.
  /// `context.itemCardPlacement` is the one shared card used by two hosts; its two values are
  /// pinned by `bothHostsOfTheItemCardStateTheirPlacement`. `ItemContextMenu.swift` forwards the
  /// modifier's own argument.
  private static let expectedPlacements: [String: [String]] = [
    "AllShowsGrid.swift": [".podcastAllShowsPageTile"],
    "DownloadsView+List.swift": [".downloadsRow"],
    "HomeMoreView.swift": [".homeMoreRow", ".homeMoreRow"],
    "HomeItemShelfCard.swift": ["context.itemCardPlacement"],
    "HomeSavedShelfCard.swift": [".homeItemCard"],
    "HomeShelfCardContext.swift": [".homeEpisodeCard"],
    "ItemContextMenu.swift": ["placement"],
    "ItemDetailView.swift": [".itemDetail"],
    "LibraryBrowseTitleInteraction.swift": [".libraryBrowseRow"],
    "PodcastEpisodeListRow.swift": ["placement"],
    "PodcastsView+Shows.swift": [".podcastsTabShowTile"],
    "SavedForLaterView.swift": [".savedForLaterRow", ".savedForLaterRow"],
    "SearchResultsList.swift": [".searchResultRow"],
  ]

  @Test("every shared-menu call site states its inventory case and no raw surface")
  func everyCallSiteStatesItsPlacement() throws {
    var found: [String: [String]] = [:]
    var violations: [String] = []

    for source in try ViewSourceScan.sources() {
      let text = try ViewSourceScan.executableText(of: source)
      let name = source.lastPathComponent
      for arguments in Self.menuCallArguments(in: text) {
        if arguments.range(of: #"(?<![A-Za-z])surface:"#, options: .regularExpression) != nil {
          violations.append("\(name) passes a raw `surface:`")
        }
        guard let placement = Self.placementValue(in: arguments) else {
          violations.append("\(name) raises the shared menu without a `placement:`")
          continue
        }
        found[name, default: []].append(placement)
      }
    }

    #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
    #expect(
      found == Self.expectedPlacements,
      """
      A shared-menu call site moved, appeared, or changed its inventory case. Pick the \
      `PodcastMenuBearingSurface` case that names the UI (adding one if none does) and update \
      this table.
      """)
  }

  /// The shared episode row forwards its caller's placement, so each caller states its own.
  @Test("the two hosts of the shared episode row state their placement")
  func bothHostsOfTheEpisodeRowStateTheirPlacement() throws {
    let latest = try ViewSourceScan.executableText(ofViewNamed: "PodcastsView")
    let smartList = try ViewSourceScan.executableText(ofViewNamed: "SmartListView")

    #expect(latest.contains("placement: .podcastsTabLatestEpisodeRow"))
    #expect(smartList.contains("placement: .smartListEpisodeRow"))
  }

  @Test("both hosts of the shared item card state their placement")
  func bothHostsOfTheItemCardStateTheirPlacement() throws {
    let home = try ViewSourceScan.executableText(ofViewNamed: "HomeView")
    let podcasts = try ViewSourceScan.executableText(ofViewNamed: "PodcastsView")

    #expect(home.contains("itemCardPlacement: .homeItemCard"))
    #expect(podcasts.contains("itemCardPlacement: .podcastsTabContinueListeningCard"))
  }

  /// The show screen's rows build their menu from Core directly rather than through the shared
  /// modifier, so they read their surface from the same inventory instead of naming one.
  @Test("the show screen's rows read their surface from the inventory")
  func showScreenRowsReadTheInventory() throws {
    let text = try ViewSourceScan.executableText(ofViewNamed: "PodcastShowViewPresentation")

    #expect(ViewSourceScan.occurrences(of: [".podcastShowEpisodeRow.menuSurface"], in: text) == 2)
    #expect(text.contains("surface: .show") == false)
  }

  @Test("the scan reads a call's whole argument list")
  func scanReadsWholeArgumentLists() {
    let text = """
      row.itemContextMenu(
        title: "a (b)", playbackStatus: { f(x) },
        placement: .homeMoreRow,
        onSearch: onSearch)
      func itemContextMenu(placement: PodcastMenuBearingSurface) {}
      ItemContextMenuContent(itemID: id, surface: .card)
      """
    let calls = Self.menuCallArguments(in: text)

    #expect(calls.count == 2)
    #expect(calls.first.flatMap(Self.placementValue(in:)) == ".homeMoreRow")
    #expect(calls.last.flatMap(Self.placementValue(in:)) == nil)
  }

  // MARK: - Scan helpers

  /// The text between each call's balanced parentheses. Declarations (`func itemContextMenu(`)
  /// are skipped; only calls are read.
  private static func menuCallArguments(in text: String) -> [String] {
    var calls: [(String.Index, String)] = []
    for marker in menuCallMarkers {
      var searchStart = text.startIndex
      while let range = text.range(of: marker, range: searchStart..<text.endIndex) {
        searchStart = range.upperBound
        if text[..<range.lowerBound].hasSuffix("func ") { continue }
        guard let arguments = balancedArguments(in: text, openingAt: text.index(before: range.upperBound))
        else { continue }
        calls.append((range.lowerBound, arguments))
      }
    }
    return calls.sorted { $0.0 < $1.0 }.map(\.1)
  }

  private static func balancedArguments(in text: String, openingAt open: String.Index) -> String? {
    var depth = 0
    var index = open
    while index < text.endIndex {
      switch text[index] {
      case "(": depth += 1
      case ")":
        depth -= 1
        if depth == 0 { return String(text[text.index(after: open)..<index]) }
      default: break
      }
      index = text.index(after: index)
    }
    return nil
  }

  nonisolated private static func placementValue(in arguments: String) -> String? {
    guard
      let match = arguments.range(
        of: #"(?<![A-Za-z])placement:\s*[A-Za-z_.]+"#, options: .regularExpression)
    else { return nil }
    return arguments[match].split(separator: ":", maxSplits: 1)[1]
      .trimmingCharacters(in: .whitespaces)
  }
}

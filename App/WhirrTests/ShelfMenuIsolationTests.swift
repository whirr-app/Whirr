import Foundation
import Testing

@testable import Whirr

/// A `List` row is one collection-view cell with one context-menu interaction, and SwiftUI
/// collapses every descendant `.contextMenu` into it, so a shelf of cards answers card 0's menu
/// wherever you press. A per-row `UIHostingController` breaks the collapse at the cost of a full
/// layout pass per row per scroll frame, and on iOS 27 the hosted cards present no menu at all.
///
/// So a shelf or grid of cards with menus lives in a stack, which has no cells, as Home and
/// Podcasts do. Put back in a `List` it compiles and looks right but answers the wrong menu, or
/// none, only when someone long-presses the third card.
@Suite("Shelf menu isolation")
struct ShelfMenuIsolationTests {
  private static let listMarkers = ["List {", "List("]
  private static let cardMenuMarkers = ["itemContextMenu("]
  /// The collapse needs several menus in one row. A list with one card per row is safe, since the
  /// cell's single interaction is the one that card wants. Only a row that lays cards out inside
  /// itself, as a shelf or grid does, has more menus than the cell can carry.
  private static let multiCardRowMarkers = ["LazyHStack", "LazyVGrid", "LazyHGrid"]

  @Test("no list row holds several card menus")
  func noListedRowHoldsSeveralCardMenus() throws {
    var violations: [String] = []

    for source in try ViewSourceScan.sources() {
      let text = try ViewSourceScan.executableText(of: source)
      guard ViewSourceScan.occurrences(of: Self.listMarkers, in: text) > 0 else { continue }
      guard ViewSourceScan.occurrences(of: Self.multiCardRowMarkers, in: text) > 0 else { continue }
      guard ViewSourceScan.occurrences(of: Self.cardMenuMarkers, in: text) > 0 else { continue }
      violations.append(source.lastPathComponent)
    }

    #expect(
      violations.isEmpty,
      """
      \(violations.joined(separator: ", ")) lays several cards out inside a List row and gives \
      them context menus. The cell will answer one card's menu for all of them, or on iOS 27 none \
      at all. Move the section out of the List into a stack, the way HomeView and \
      PodcastsView do.
      """)
  }

  /// The two browse roots with card shelves. If either returns to a `List`, the scan above applies
  /// to it again, so the container is pinned here.
  @Test("Home and Podcasts browse in a stack, not a list")
  func browseRootsAvoidTheListCell() throws {
    for fileName in ["HomeView.swift", "PodcastsView.swift"] {
      let text = try ViewSourceScan.executableText(ofFileNamed: fileName)
      #expect(ViewSourceScan.occurrences(of: ["VStack("], in: text) > 0, "\(fileName)")
      #expect(ViewSourceScan.occurrences(of: Self.listMarkers, in: text) == 0, "\(fileName)")
    }
  }

  /// Home holds at most one row per shelf kind, and each shelf's cards stay lazy inside it. In a
  /// lazy page, every row that scrolls back into range is rebuilt and its strip re-measured. That
  /// ran during every Home hitch on device. Podcasts holds unbounded lists, so it stays lazy.
  @Test("Home keeps its shelves alive in an eager stack; Podcasts stays lazy")
  func homePageIsEagerAndPodcastsIsLazy() throws {
    let home = try ViewSourceScan.executableText(ofFileNamed: "HomeView.swift")
    let podcasts = try ViewSourceScan.executableText(ofFileNamed: "PodcastsView.swift")
    #expect(ViewSourceScan.occurrences(of: ["LazyVStack"], in: home) == 0)
    #expect(ViewSourceScan.occurrences(of: ["LazyVStack"], in: podcasts) > 0)
  }
}

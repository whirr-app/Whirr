import Foundation
import Testing

@testable import Whirr

/// SC 2.5.7 (Dragging Movements) for the two places where a drag is the only pointer route.
///
/// `.accessibilityAction(named:)` is not enough: it reaches only VoiceOver's rotor, while the
/// criterion serves motor impairment (head pointer, switch, unsteady hand). Source-level gates,
/// as a test cannot read SwiftUI's modifier tree back. See `ViewSourceScan`.
@Suite("Pointer alternatives to dragging")
struct DragAlternativeTests {

  /// The expanded player closes by pulling the page down. The handle at the top looks like that
  /// affordance but cannot be tapped, so it read as interactive to everyone and no pointer could
  /// operate it.
  @Test("the expanded player's close handle is a button, not a drag affordance with a label")
  func dismissHandleIsTappable() throws {
    let text = try ViewSourceScan.executableText(ofFileNamed: "ExpandedPlayerView.swift")
    let handle = try #require(text.range(of: "private var dismissHandle: some View {"))
    let body = String(text[handle.lowerBound...].prefix(700))

    #expect(body.contains("Button"))
    #expect(body.contains("navigation.collapsePlayer()"))
    // A real Button replaces the hand-rolled element. Leaving it would put a button trait on a
    // container that touch still cannot activate.
    #expect(body.contains(".accessibilityAction {") == false)
    #expect(body.contains(".accessibilityAddTraits(.isButton)") == false)
  }

  /// Reordering the all-shows grid is drag-and-drop, and edit mode turns off the tile's context
  /// menu, which leaves the moves on the rotor alone. Both sources draw through `AllShowsGrid`, so
  /// one scan covers the server and followed screens.
  @Test("an all-shows tile in edit mode offers both moves without a drag")
  func editingTileOffersMoveItems() throws {
    let text = try ViewSourceScan.executableText(ofFileNamed: "AllShowsGrid.swift")
    let helper = try #require(text.range(of: "private func accessibleEditingTile("))
    let body = String(text[helper.lowerBound...].prefix(2400))

    #expect(body.contains(".contextMenu {"))
    #expect(body.contains("PodcastShowAccessibilityMove.earlier.label"))
    #expect(body.contains("PodcastShowAccessibilityMove.later.label"))
    // Shown greyed out at a boundary, not dropped. The rotor actions for the same two moves drop
    // them.
    #expect(
      ViewSourceScan.occurrences(
        of: ["moves.contains(.earlier) == false", "moves.contains(.later) == false"], in: body)
        == 2)
  }
}

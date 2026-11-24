import SwiftUI
import Testing

@testable import DesignSystem

/// The episode row's menus are compared on their sections alone, so a caller that re-renders the
/// row on every playhead tick (the show page's row prints the live position) does not rebuild a
/// presented menu under the listener. That rebuild visibly pulses the menu's glass.
@Suite("Podcast episode row action menu")
@MainActor
struct PodcastEpisodeRowActionMenuTests {
  private static let sections: [[MediaContextAction]] = [
    [MediaContextAction(id: "play", label: "Play Episode", hint: "", systemImage: "play.fill")],
    [
      MediaContextAction(
        id: "remove", label: "Remove Download", hint: "", systemImage: "trash",
        role: .destructive)
    ],
  ]

  @Test("the ellipsis menu is equal across re-renders that keep its sections")
  func ellipsisMenuIgnoresItsClosure() {
    let first = PodcastEpisodeRowActionMenu(
      sections: Self.sections, accessibilityLabel: "Episode actions",
      accessibilityHint: "hint", minimumWidth: 44, minimumHeight: 44, onSelectAction: { _ in })
    let second = PodcastEpisodeRowActionMenu(
      sections: Self.sections, accessibilityLabel: "Episode actions",
      accessibilityHint: "hint", minimumWidth: 44, minimumHeight: 44, onSelectAction: { _ in })
    #expect(first == second)
  }

  @Test("the long-press items are equal across re-renders that keep their sections")
  func longPressItemsIgnoreTheirClosure() {
    #expect(
      MediaActionMenuItems(sections: Self.sections, onSelectAction: { _ in })
        == MediaActionMenuItems(sections: Self.sections, onSelectAction: { _ in }))
  }

  @Test("a changed section still rebuilds the menu")
  func changedSectionsRebuild() {
    let fewer = Array(Self.sections.prefix(1))
    #expect(
      MediaActionMenuItems(sections: Self.sections, onSelectAction: { _ in })
        != MediaActionMenuItems(sections: fewer, onSelectAction: { _ in }))
    #expect(
      PodcastEpisodeRowActionMenu(
        sections: Self.sections, accessibilityLabel: "Episode actions",
        accessibilityHint: "hint", minimumWidth: 44, minimumHeight: 44, onSelectAction: { _ in })
        != PodcastEpisodeRowActionMenu(
          sections: fewer, accessibilityLabel: "Episode actions",
          accessibilityHint: "hint", minimumWidth: 44, minimumHeight: 44, onSelectAction: { _ in }))
  }

  /// A submenu's choices are part of the comparison: a device that starts sending must redraw.
  @Test("a changed submenu choice still rebuilds the items")
  func changedChildRebuilds() {
    func submenu(sendingEnabled: Bool) -> [[MediaContextAction]] {
      [
        [
          MediaContextAction(
            id: "send", label: "Send to E-reader", hint: "", systemImage: "paperplane",
            children: [
              MediaContextAction(
                id: "send.kindle", label: "Kindle", hint: "", systemImage: "",
                isEnabled: sendingEnabled)
            ])
        ]
      ]
    }
    #expect(submenu(sendingEnabled: true).first?.first?.isSubmenu == true)
    #expect(
      MediaActionMenuItems(sections: submenu(sendingEnabled: true), onSelectAction: { _ in })
        != MediaActionMenuItems(sections: submenu(sendingEnabled: false), onSelectAction: { _ in }))
  }
}

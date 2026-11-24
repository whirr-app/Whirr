import AppModel
import DesignSystem
import SwiftUI

/// The episode card's canonical action menu, kept outside the card's own redraw scope.
///
/// The card shows the playhead in three places, so its body re-runs each position persist, every
/// fifteen seconds (`PlaybackSessionCoordinator.progressPersistInterval`), and rebuilding a
/// presented `Menu`'s source visibly pulses its glass. No row depends on the playhead (coarse
/// status, download state, membership), so the rows are derived once and compared with
/// `.equatable()` at the call site; a tick never reaches the menu. `QuickActionsControls` draws
/// the same boundary around the player's menus.
struct PodcastEpisodeCardActionMenu: View, Equatable {
  let sections: [[PodcastEpisodeCardViewPresentation.ActionRow]]
  let perform: (AppModel.MediaItemAction) -> Void

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.sections == rhs.sections }

  var body: some View {
    Menu {
      PodcastEpisodeCardActionMenuItems(sections: sections, perform: perform)
    } label: {
      Image(systemName: "ellipsis")
        .episodeCardControlChrome()
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Episode actions")
    .accessibilityHint("Shows playback, saved, navigation, download, and progress actions.")
  }
}

/// The rows, shared by the ellipsis menu and the header's long-press context menu so the two
/// cannot diverge. Equatable because a long-pressed context menu is also presented over the
/// ticking card.
struct PodcastEpisodeCardActionMenuItems: View, Equatable {
  let sections: [[PodcastEpisodeCardViewPresentation.ActionRow]]
  let perform: (AppModel.MediaItemAction) -> Void

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.sections == rhs.sections }

  var body: some View {
    MediaActionMenuItems(sections: PodcastEpisodeCardViewPresentation.menuRows(sections)) {
      display in
      if let row = sections.joined().first(where: { $0.id == display.id }) {
        perform(row.action)
      }
    }
  }
}

extension View {
  /// A secondary card control's body at the play row's shared diameter, used by save, download and
  /// overflow (their wrappers stay plain, adding no chrome). The tertiary fill lets the sheet's
  /// wash show through. It is a concrete colour, not the hierarchical `.tertiary`: at the half
  /// detent the sheet is glass and a hierarchical style goes vibrant only where SwiftUI hosts the
  /// view in the sheet's context, and a `Menu` label is hosted apart, so the ellipsis would blend
  /// plainly while save and download went darker. A concrete colour is never vibrant, so all match.
  func episodeCardControlChrome() -> some View {
    self
      .font(WhirrTypeToken.headline.font)
      .circularControlChrome(
        diameter: PodcastEpisodeCardViewPresentation.Metric.controlDiameter,
        hitTargetDiameter: PodcastEpisodeCardViewPresentation.Metric.controlDiameter,
        fill: Color(uiColor: .tertiaryLabel))
  }
}

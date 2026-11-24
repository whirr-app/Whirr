import AppModel
import DesignSystem
import Persistence
import PlayerCore
import SwiftUI
import TipKit

/// The overflow trigger at the trailing edge of the metadata block, the way Apple Music seats the
/// same control.
///
/// Equatable like `QuickActionsControls`: its parent reads the live playhead, so its body runs
/// every tick, and a `Menu` rebuilt mid-gesture closes under the finger. Everything the menu
/// reads is in `Identity`; anything omitted would freeze at its first value for the session.
struct MetadataOverflowControl: View, Equatable {
  let itemID: String
  let episodeID: String?
  /// What "mark as finished" would write. From the item's own length, never the playhead.
  let duration: Double?
  /// The coarse progress state behind the menu's finish/reset entries.
  let playbackStatus: ItemPlaybackStatus?
  let playback: PlaybackModel
  let actions: ItemActionsModel
  let includesHistory: Bool
  /// Raises the page's listening-history sheet. Excluded from `==`: a closure is not comparable,
  /// and it changes only when the page it belongs to does.
  let onShowHistory: () -> Void
  let supplementCount: Int
  /// Raises the page's supplements sheet. Excluded from `==` like `onShowHistory`.
  let onShowSupplements: () -> Void
  /// Leaves for the item's detail surface. Excluded from `==` like `onShowHistory`, safely: the
  /// destination is a function of `itemID`/`episodeID`, both carried by `Identity`.
  let onViewDetails: () -> Void
  /// Saves a bookmark at the playhead; `nil` hides the entry. Only its presence is in `Identity`:
  /// the closure reads the playhead when chosen, so it needs no rebuild as the position moves.
  var onAddBookmark: (() -> Void)? = nil
  /// Raises the page's transcript sheet; `nil` hides the entry. Only its presence is in
  /// `Identity`, like `onAddBookmark`.
  var onShowTranscript: (() -> Void)? = nil
  /// Raises the page's Look Back sheet; `nil` hides the entry. Only its presence is in `Identity`.
  var onShowLookBack: (() -> Void)? = nil

  struct Identity: Equatable {
    let itemID: String
    let episodeID: String?
    let duration: Double?
    let playbackStatus: ItemPlaybackStatus?
    let includesHistory: Bool
    let supplementCount: Int
    let includesAddBookmark: Bool
    let includesTranscript: Bool
    var includesLookBack = false
  }

  var identity: Identity {
    Identity(
      itemID: itemID, episodeID: episodeID, duration: duration, playbackStatus: playbackStatus,
      includesHistory: includesHistory, supplementCount: supplementCount,
      includesAddBookmark: onAddBookmark != nil, includesTranscript: onShowTranscript != nil,
      includesLookBack: onShowLookBack != nil)
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.identity == rhs.identity
  }

  var body: some View {
    PlayerOverflowMenu(
      itemID: itemID, episodeID: episodeID, duration: duration, playbackStatus: playbackStatus,
      playback: playback, actions: actions, includesHistory: includesHistory,
      onShowHistory: onShowHistory, supplementCount: supplementCount,
      onShowSupplements: onShowSupplements, onViewDetails: onViewDetails,
      onAddBookmark: onAddBookmark, onShowTranscript: onShowTranscript,
      onShowLookBack: onShowLookBack
    ) {
      MetadataOverflowTrigger()
    }
    .buttonStyle(.plain)
    // Introduces Look Back after a sleep timer paused this book, or Transcript on an episode
    // (`PlayerOverflowTip`).
    .popoverTip(
      PlayerOverflowTip.choice(
        includesLookBack: onShowLookBack != nil, includesTranscript: onShowTranscript != nil)?.tip,
      arrowEdge: .top
    )
    // Aligns the drawn circle with the metadata column's trailing margin (the line the title's
    // leading edge sits on) by letting the touch target hang past it into the page gutter. Without
    // this the column's padding lands on the target's edge and the disc reads as tucked in.
    .padding(.trailing, -PlayerMetric.metadataOverflowTargetOverhang)
  }
}

/// What the trigger draws, apart from its menu so the treatment is testable without the player's
/// models. A filled circle, the secondary-control body the podcast episode sheet gives its
/// download and ellipsis buttons (shared chrome stops drift); real glass reads as a lens over the
/// artwork, and the expanded player has a no-glass rule. Lighter than the sheet's: drawn below
/// the touch minimum and padded out, with a fainter fill, since it sits beside the title and must
/// not read as a second thing to look at, where the sheet's holds its own beside a Resume capsule.
struct MetadataOverflowTrigger: View {
  var body: some View {
    Image(systemName: PlayerOverflowMenuPresentation.symbol)
      .font(
        .system(
          size: PlayerMetric.metadataOverflowSymbolSize,
          weight: PlayerMetric.quickActionSymbolWeight)
      )
      .circularControlChrome(
        diameter: PlayerMetric.metadataOverflowDiameter,
        hitTargetDiameter: PlayerMetric.metadataOverflowTargetDiameter,
        fill: .quaternary)
  }
}

import AppModel
import SwiftUI
import UIKit

/// End state of the player's host view for one non-interactive collapse, resolved from the style
/// the navigation model recorded. Pure so it is testable without a transition context.
enum PlayerCollapseMotion: Equatable {
  case slide(translationY: CGFloat)
  case dissolve(alpha: CGFloat, scale: CGFloat)
  /// The page folds into the mini player, whose geometry was read as the collapse began.
  case morph(PlayerMorphGeometry.Snapshot)

  /// `geometry` is the relay's answer for this collapse, `nil` when there is no bar to land on.
  /// A morph is how a `.slide` is rendered when there is somewhere to land; it is not a model
  /// state of its own.
  static func resolve(
    style: NavigationModel.PlayerCollapseStyle,
    containerHeight: CGFloat,
    reduceMotion: Bool,
    geometry: PlayerMorphGeometry.Snapshot? = nil
  ) -> PlayerCollapseMotion {
    switch style {
    case .slide:
      // Reduce Motion keeps the short slide: the morph is all positional movement.
      if reduceMotion == false, let geometry {
        return .morph(geometry)
      }
      return .slide(translationY: containerHeight)
    case .dissolve:
      // Reduce Motion keeps the fade and drops the scale: the setting asks against positional
      // movement.
      return .dissolve(
        alpha: 0, scale: reduceMotion ? 1 : ExpandedPlayerHostPresentation.dissolveEndScale)
    }
  }

  /// `morphs` says whether `resolve` chose a morph for this collapse. UIKit times the shell dim
  /// from this duration, so it has to be the duration of the motion that actually runs.
  static func duration(
    style: NavigationModel.PlayerCollapseStyle, reduceMotion: Bool, morphs: Bool = false
  ) -> TimeInterval {
    if reduceMotion {
      return 0.2
    }
    if morphs {
      return ExpandedPlayerHostPresentation.morphDuration
    }
    switch style {
    case .slide: return ExpandedPlayerHostPresentation.slideDuration
    case .dissolve: return ExpandedPlayerHostPresentation.dissolveDuration
    }
  }

  var isMorph: Bool {
    if case .morph = self { return true }
    return false
  }
}

/// How the page arrives. Not `PlayerCollapseMotion`: an open has no style and no dissolve.
enum PlayerOpenMotion: Equatable {
  /// Up from the bottom edge: no bar to grow from, or Reduce Motion.
  case slide
  /// Out of the mini player, whose geometry was read as the open began.
  case morph(PlayerMorphGeometry.Snapshot)
}

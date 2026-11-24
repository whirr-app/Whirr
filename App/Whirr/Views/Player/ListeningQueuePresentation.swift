import SwiftUI

/// The listening queue sheet's presentation policy: a pure function of horizontal size class, so a
/// constant can flip without rewriting a view. Regular width is a form sheet, not a popover, with
/// no source morph (it doesn't work for `tabViewBottomAccessory`).
enum ListeningQueuePresentation {

  /// Which system presentation the queue sheet uses. `.formSheet` is an anchored, self-sizing
  /// form-style sheet on regular width, not a popover.
  enum Style: Equatable {
    case sheet
    case formSheet
  }

  /// The detents the compact sheet resolves through, in presentation order: medium, expandable
  /// to large. Same medium/large idiom as `PodcastEpisodeCardViewPresentation.detents`.
  static let compactDetents: [PresentationDetent] = [.medium, .large]

  /// The detent a freshly presented compact sheet starts at.
  static let initialDetent: PresentationDetent = .medium

  /// Compact width (including an unresolved/nil size class) gets the resizable sheet; regular
  /// width gets a form sheet, never a popover.
  static func style(horizontalSizeClass: UserInterfaceSizeClass?) -> Style {
    horizontalSizeClass == .regular ? .formSheet : .sheet
  }

  /// `compactDetents` for the compact sheet; a regular-width form sheet sizes itself and offers no
  /// resizable detents.
  static func detents(for style: Style) -> [PresentationDetent] {
    switch style {
    case .sheet: compactDetents
    case .formSheet: []
    }
  }
}

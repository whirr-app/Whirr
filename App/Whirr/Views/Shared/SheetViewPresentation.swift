import SwiftUI

/// Semantic sheet roles shared by App-owned hosts. The policy describes the presentation contract
/// without choosing a view or reading the environment; each host applies the matching SwiftUI
/// modifiers after resolving its local size class.
nonisolated enum SheetViewPresentation {
  enum Role: Equatable {
    case episodeCard
    case large
    case form
    case fitted
    /// A full page-sized card at regular width whose content scrolls and loads after presentation.
    /// Unlike `.episodeCard`, the shared host must not fit it vertically: a scroll view measured
    /// while loading has the ideal height of a spinner.
    case page
    case exemption
  }

  enum Mode: Equatable {
    case compactDetents
    case compactLarge
    case regularPage
    case regularForm
    case regularFitted
    case regularFullPage
    case exempt
  }

  static func mode(
    for horizontalSizeClass: UserInterfaceSizeClass?,
    role: Role
  ) -> Mode {
    let isRegular = horizontalSizeClass == .regular

    switch role {
    case .episodeCard:
      return isRegular ? .regularPage : .compactDetents
    case .large:
      return isRegular ? .regularForm : .compactLarge
    case .form:
      return isRegular ? .regularForm : .compactDetents
    case .fitted:
      return isRegular ? .regularFitted : .compactDetents
    case .page:
      return isRegular ? .regularFullPage : .compactLarge
    case .exemption:
      return .exempt
    }
  }
}

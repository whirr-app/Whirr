import AppModel
import DesignSystem
import ReaderCore
import SwiftUI

/// The actions behind the reader's toolbar menu, in menu order.
enum ReaderMenuAction: Hashable, CaseIterable {
  case contents
  case search
  case appearance

  var systemImage: String {
    switch self {
    case .contents: "list.bullet"
    case .search: "magnifyingglass"
    case .appearance: "textformat.size"
    }
  }

  var accessibilityIdentifier: String {
    switch self {
    case .contents: ReaderAccessibilityID.toc
    case .search: ReaderAccessibilityID.search
    case .appearance: ReaderAccessibilityID.appearance
    }
  }
}

enum ReaderTapIntent: Equatable {
  case toggleChrome
  case turnPage(ReaderPageDirection)
}

/// App-side translation and semantic contracts for the reader composition. The two ReaderTheme
/// enums are qualified at their call sites: ReaderCore owns persisted preferences, while
/// DesignSystem owns the three visual palettes.
enum ReaderPresentation {
  static let isFullScreenCover = true

  /// Returns the presenting window to the app's own appearance before the cover starts revealing
  /// it. Waiting for `onDisappear` or `fullScreenCover`'s `onDismiss` leaves the reader's scheme on
  /// the underlying shell for the first frame of the dismissal transition.
  static func dismiss(
    onThemeChange: (DesignSystem.ReaderTheme?) -> Void,
    dismissCover: () -> Void,
    leaveReader: () -> Void = {}
  ) {
    onThemeChange(nil)
    // This helper runs before the full-screen cover begins dismissing, ahead of ReaderView's
    // onDisappear, so the borrowed screen level is restored before the library is revealed.
    leaveReader()
    dismissCover()
  }

  static func isStatusBarHidden(chromeVisible: Bool) -> Bool {
    chromeVisible == false
  }

  /// The bottom bar's items are system toolbar items, so the chrome toggle is the bar's own
  /// visibility rather than views moving in and out. The close button is inserted with the chrome.
  static func toolbarVisibility(chromeVisible: Bool) -> Visibility {
    chromeVisible ? .visible : .hidden
  }

  /// The bottom bar's width left to the rail once the menu (and the finish offer, while it shows)
  /// take theirs. Capped so a wide iPad bar does not turn a hairline into a ruler.
  static func railWidth(containerWidth: CGFloat, showsFinishOffer: Bool) -> CGFloat {
    // The bar's margins, the menu button, and the spacer. On an iPhone 18 Pro a 104-point
    // reservation had the system fold the rail into an overflow menu instead of drawing it; 140
    // draws it with even margins. The finish offer's and appearance button's allowances are
    // unchecked on a device.
    let reserved: CGFloat =
      140 + (showsFinishOffer ? 210 : 0)
      + (showsAppearanceButton(isFinishOfferVisible: showsFinishOffer) ? appearanceButtonWidth : 0)
    return min(max(containerWidth - reserved, 88), 560)
  }

  /// The rail's width, also kept within the room between where the bar placed the rail and the
  /// page's trailing edge, both in global coordinates.
  ///
  /// The system can confine the bottom bar to part of the page (one half of a half-open iPhone
  /// Duo), and nothing reports that region. The bar places an overflowing rail at the region's
  /// leading edge and centres one that fits. The measurement feeds back into the width, but it
  /// settles: a rail too wide narrows to the region in one pass, and a narrowed rail centred in a
  /// wider bar reports more room each pass until the 560-point cap or the region stops it. Whole
  /// points end the passes.
  static func railWidth(
    containerWidth: CGFloat, showsFinishOffer: Bool, railLeading: CGFloat?, pageTrailing: CGFloat
  ) -> CGFloat {
    let width = railWidth(containerWidth: containerWidth, showsFinishOffer: showsFinishOffer)
    guard let railLeading else { return width }
    return max(min(width, (pageTrailing - railLeading).rounded(.down)), 88)
  }

  /// The rail's inset inside its glass capsule, taken from the rail's width rather than added to
  /// it, so the reservation above still decides whether the system folds the rail away.
  static let railCapsuleInset: CGFloat = 14

  /// The appearance button's share of the bar, beside the menu in the same glass group.
  static let appearanceButtonWidth: CGFloat = 48

  /// Appearance is the menu's one frequent, in-place action, so it gets its own button, except
  /// while the finish offer shows: a phone bar has no room for both beside a usable rail.
  static func showsAppearanceButton(isFinishOfferVisible: Bool) -> Bool {
    isFinishOfferVisible == false
  }

  /// The customise page's sample stands in for a page the full-height sheet covers. At half
  /// height the page shows above the sheet, so the sample would only crowd out the controls.
  static func showsTypographySample(
    level: ReaderAppearanceLevel, detent: PresentationDetent
  ) -> Bool {
    level == .customise && detent == .large
  }

  static func menuActions(isSearchable: Bool, isFinishOfferVisible: Bool) -> [ReaderMenuAction] {
    var actions: [ReaderMenuAction] = isSearchable ? [.contents, .search] : [.contents]
    if showsAppearanceButton(isFinishOfferVisible: isFinishOfferVisible) == false {
      actions.append(.appearance)
    }
    return actions
  }

  static func intent(for zone: ReadiumEPUBTapZone) -> ReaderTapIntent {
    switch zone {
    case .left: return .turnPage(.left)
    case .center: return .toggleChrome
    case .right: return .turnPage(.right)
    }
  }

  static func designTheme(
    for theme: ReaderCore.ReaderTheme, systemScheme: ColorScheme
  ) -> DesignSystem.ReaderTheme {
    switch theme {
    case .system: return systemScheme == .dark ? .dark : .light
    case .light: return .light
    case .sepia: return .sepia
    case .dark: return .dark
    }
  }

  /// The window appearance a reading theme asks for. The reader applies this itself, because a
  /// `preferredColorScheme` on the presenting view never reaches a full-screen cover's status bar,
  /// which stays on the app's stored appearance, so a light page would keep white glyphs.
  static func windowScheme(for theme: DesignSystem.ReaderTheme) -> ColorScheme {
    switch theme {
    case .light, .sepia: return .light
    case .dark: return .dark
    }
  }

  static func coreTheme(for theme: DesignSystem.ReaderTheme) -> ReaderCore.ReaderTheme {
    switch theme {
    case .light: return .light
    case .sepia: return .sepia
    case .dark: return .dark
    }
  }

  static func designAlignment(
    for alignment: ReaderCore.ReaderTextAlignment
  ) -> DesignSystem.ReaderTextAlignment {
    switch alignment {
    case .publisherDefault: return .publisherDefault
    case .left: return .left
    case .justify: return .justify
    }
  }

  static func coreAlignment(
    for alignment: DesignSystem.ReaderTextAlignment
  ) -> ReaderCore.ReaderTextAlignment {
    switch alignment {
    case .publisherDefault: return .publisherDefault
    case .left: return .left
    case .justify: return .justify
    }
  }

  static func designFont(for family: ReaderCore.ReaderFontFamily) -> DesignSystem.ReaderFontFamily {
    switch family {
    case .publisherDefault: return .publisher
    case .serif: return .serif
    case .sansSerif: return .sansSerif
    case .monospaced: return .monospaced
    case .openDyslexic: return .openDyslexic
    }
  }

  static func coreFont(for family: DesignSystem.ReaderFontFamily) -> ReaderCore.ReaderFontFamily {
    switch family {
    case .publisher: return .publisherDefault
    case .serif: return .serif
    case .sansSerif: return .sansSerif
    case .monospaced: return .monospaced
    case .openDyslexic: return .openDyslexic
    }
  }

}

enum ReaderAccessibilityID {
  static let screen = "reader.screen"
  static let back = "reader.back"
  static let menu = "reader.menu"
  static let toc = "reader.toc"
  static let search = "reader.search"
  static let appearance = "reader.appearance"
  static let page = "reader.page"
  static let progress = "reader.progress"
  static let appearanceSheet = "reader.appearanceSheet"
  static let tocSheet = "reader.tocSheet"
  static let searchSheet = "reader.searchSheet"
  static let finishOffer = "reader.finishOffer"
  static let returnOffer = "reader.returnOffer"
  static let previousPage = "reader.previousPage"
  static let nextPage = "reader.nextPage"

  static let appearancePanel = "reader.appearance.panel"

  static func tocRow(_ index: Int) -> String { "reader.toc.row.\(index)" }

  static func searchRow(_ index: Int) -> String { "reader.search.row.\(index)" }

  /// The panel's own controls are namespaced by DesignSystem from this prefix, so App keeps
  /// ownership of the namespace without DesignSystem owning any copy.
  static func appearanceControl(_ suffix: String) -> String { "\(appearancePanel).\(suffix)" }

  static let order = [screen, back, menu, toc, search, appearance, page, progress]
}

import DesignSystem
import SwiftUI
import UIKit

/// The listener's app-wide appearance preference. Storing the semantic choice rather than the
/// currently resolved system scheme means "System" continues to follow changes made in Settings,
/// Control Center, and automatic day/night schedules.
nonisolated enum AppAppearance: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  static let storageKey = "app.appearance"

  var id: Self { self }

  var displayName: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  var preferredColorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }

  /// The same choice stated as a concrete scheme, for surfaces that cannot express "no preference".
  /// A presented sheet owns its own colour-scheme preference boundary and does not give one up
  /// again: once Settings had been told `.light`, a later `nil` left it white while the rest of the
  /// app followed the device back to dark. `ambient` is the scheme the presenting shell is showing
  /// (already resolved against the device by the app-level preference), so System just adopts it.
  func colorScheme(ambient: ColorScheme) -> ColorScheme {
    preferredColorScheme ?? ambient
  }

  @MainActor
  static func applyNavigationBarAppearance() {
    let navigationBar = UINavigationBar.appearance()
    let largeTitleFont = navigationFont(
      face: .bold, textStyle: .largeTitle, uiTextStyle: .largeTitle)
    let titleFont = navigationFont(face: .medium, textStyle: .headline, uiTextStyle: .headline)

    func applyTextAttributes(to appearance: UINavigationBarAppearance) {
      var largeTitleTextAttributes = appearance.largeTitleTextAttributes
      largeTitleTextAttributes[.font] = largeTitleFont
      appearance.largeTitleTextAttributes = largeTitleTextAttributes

      var titleTextAttributes = appearance.titleTextAttributes
      titleTextAttributes[.font] = titleFont
      appearance.titleTextAttributes = titleTextAttributes
    }

    let standardAppearance = navigationBar.standardAppearance
    applyTextAttributes(to: standardAppearance)
    navigationBar.standardAppearance = standardAppearance

    if let scrollEdgeAppearance = navigationBar.scrollEdgeAppearance {
      applyTextAttributes(to: scrollEdgeAppearance)
      navigationBar.scrollEdgeAppearance = scrollEdgeAppearance
    }

    if let compactAppearance = navigationBar.compactAppearance {
      applyTextAttributes(to: compactAppearance)
      navigationBar.compactAppearance = compactAppearance
    }
  }

  @MainActor
  private static func navigationFont(
    face: WhirrDisplayFont.Face,
    textStyle: Font.TextStyle,
    uiTextStyle: UIFont.TextStyle
  ) -> UIFont {
    let baseSize = WhirrDisplayFont.basePointSize(for: textStyle)
    let fallbackWeight: UIFont.Weight = face == .bold ? .bold : .semibold
    if WhirrDisplayFont.isFamilyAvailable,
      let displayFont = WhirrDisplayFont.scaledUIFont(
        face: face, textStyle: textStyle, uiTextStyle: uiTextStyle)
    {
      return displayFont
    }

    let fallbackFont = UIFont.systemFont(ofSize: baseSize, weight: fallbackWeight)
    return UIFontMetrics(forTextStyle: uiTextStyle).scaledFont(for: fallbackFont)
  }

  static func resolved(_ storedValue: String) -> Self {
    Self(rawValue: storedValue) ?? .system
  }
}

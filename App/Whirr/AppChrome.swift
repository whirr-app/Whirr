import DesignSystem
import SwiftUI
import UIKit

/// The app's own chrome styling, applied once at the scene root.
enum AppChrome {
  /// The neutral app tint for controls that name no colour. Read by name because SwiftUI under the
  /// iOS 26 SDK ignores the catalog's global accent and falls back to system blue.
  /// `ExpandedPlayerView`, item detail and the login flow set their own.
  static let tint = Color("AccentColor")

  /// Whirr's navy for switch on-states in Settings and the setup flow (`SetupFlowView.tint`). Dark
  /// uses a lifted, desaturated navy: the pale `brandInk` loses a switch's white thumb, the light
  /// navy its track. Clears 4.5:1 against white for `.borderedProminent` labels.
  static let brandTint = Color(
    uiColor: UIColor { traits in
      let rgb =
        traits.userInterfaceStyle == .dark
        ? WhirrRGBColor(88.0 / 255.0, 120.0 / 255.0, 154.0 / 255.0)
        : WhirrColorToken.brandInk.lightRGB
      return UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    })

  /// The tint of a `List(selection:)` multiselect circle, which always draws a white tick: `tint`
  /// is near-white in dark appearance, so this navy carries a white mark in both.
  static let selectionMarkTint = brandTint

  /// The label colour that reads on top of `tint`. `.borderedProminent` paints its label white
  /// whatever the tint, and `tint` is near-white in dark mode, so a prominent button must state
  /// this itself. The system background is the inverse in both appearances because `tint` tracks
  /// them.
  static let onTint = Color(uiColor: .systemBackground)
}

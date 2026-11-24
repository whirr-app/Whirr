import DesignSystem
import SwiftUI
import Testing
import UIKit

@testable import Whirr

/// Light and dark proof for the app-chrome tint. Here, not in `DesignSystemTests`, because
/// resolving a dynamic colour needs a real `UITraitCollection`.
///
/// Regression: under the iOS 26 SDK SwiftUI does not adopt the asset catalog's `AccentColor` as
/// the default tint, so uncoloured controls (progress bars, See All, the selected tab) fell back
/// to system blue. The app root now tints explicitly; these tests pin that value.
@Suite("App chrome tint")
struct AppChromeTintTests {

  @Test("the chrome tint is near-white in the dark appearance and graphite in the light one")
  func chromeTintTracksTheAppearance() {
    #expect(AppChrome.tint.resolved(.dark).isCloserToWhite)
    #expect(!AppChrome.tint.resolved(.light).isCloserToWhite)
  }

  /// Untinted controls resolve to `Color.accentColor`, which must differ from the neutral value. If
  /// they match, the chrome is blue again.
  @Test("the chrome tint is not whatever an untinted control falls back to")
  func chromeTintIsNotTheImplicitDefault() {
    #expect(AppChrome.tint.resolved(.dark) != Color.accentColor.resolved(.dark))
  }

  /// Menu pickers inherit this tint, which `DownloadSettingsView` relies on. The neutral's dark
  /// value is near-white, so this checks it stays readable against a dark grouped surface, where a
  /// picker's value and chevron are drawn, in both appearances. If either pairing collapses, a
  /// dropdown goes invisible.
  @Test("the neutral chrome tint stays legible on the grouped surface a picker is drawn on")
  func chromeTintContrastsWithTheGroupedSurface() {
    for style in [UIUserInterfaceStyle.light, .dark] {
      let ratio = contrastRatio(
        AppChrome.tint.resolved(style), WhirrColorToken.groupedSurface.color.resolved(style))
      #expect(ratio >= 4.5, "tint vs grouped surface in \(style)")
    }
  }

  @Test("brand tint uses branded navy in light appearance and a lifted navy in dark")
  func brandTintTracksTheAppearance() {
    #expect(AppChrome.brandTint.resolved(.light) == WhirrColorToken.brandInk.lightRGB)
    #expect(
      AppChrome.brandTint.resolved(.dark)
        == WhirrRGBColor(88.0 / 255.0, 120.0 / 255.0, 154.0 / 255.0))
    #expect(AppChrome.brandTint.resolved(.light) != AppChrome.brandTint.resolved(.dark))
  }

  /// A switch needs two visible boundaries: the on-track against the row, and the white thumb
  /// against the track. The dark tint is mid-value rather than near-white (`brandInk.darkRGB`),
  /// which would merge the second boundary.
  @Test("brand tint keeps a switch track and thumb distinct in both appearances")
  func brandTintHasNonTextContrast() {
    let whiteThumb = WhirrRGBColor(1, 1, 1)

    for style in [UIUserInterfaceStyle.light, .dark] {
      let tint = AppChrome.brandTint.resolved(style)
      let surface = WhirrColorToken.groupedSurface.color.resolved(style)
      #expect(contrastRatio(tint, surface) >= 3, "track vs grouped surface in \(style)")
      #expect(contrastRatio(tint, whiteThumb) >= 3, "white thumb vs track in \(style)")
    }
  }

  /// A native `List(selection:)` fills its multiselect circle with the inherited tint and draws a
  /// white tick inside it. The neutral tint is near-white in dark mode, which left a white tick on
  /// a white disc. The selection mark therefore states the navy, and it must clear the same
  /// white-on-tint bar a prominent label does.
  @Test("the selection mark's disc carries its white tick in both appearances")
  func selectionMarkTintCarriesAWhiteTick() {
    let white = WhirrRGBColor(1, 1, 1)

    for style in [UIUserInterfaceStyle.light, .dark] {
      let ratio = contrastRatio(AppChrome.selectionMarkTint.resolved(style), white)
      #expect(ratio >= 4.5, "white selection tick vs its disc in \(style)")
    }
  }

  /// The neutral tint fails that bar in dark mode, which is why the mark cannot inherit it. If it
  /// ever passes, `AccentColor`'s dark value has moved and the separate selection tint needs
  /// re-examining.
  @Test("the neutral chrome tint could not have carried that tick in the dark appearance")
  func neutralTintCannotCarryTheSelectionTick() {
    #expect(contrastRatio(AppChrome.tint.resolved(.dark), WhirrRGBColor(1, 1, 1)) < 4.5)
  }

  /// The setup flow tints its whole `ZStack`, so a bare bright blue literal reached every control
  /// on the screen: library switches, prominent buttons and `.foregroundStyle(.tint)` links. Naming
  /// the shared brand tint keeps login and Settings the same navy.
  @Test("the setup flow tints itself with the brand navy rather than a blue literal")
  func setupFlowUsesTheBrandTint() {
    for style in [UIUserInterfaceStyle.light, .dark] {
      #expect(SetupFlowView.tint.resolved(style) == AppChrome.brandTint.resolved(style))
      #expect(SetupFlowView.tint.resolved(style) != WhirrRGBColor(0.18, 0.58, 0.96))
    }
  }

  /// `.borderedProminent` fills with the inherited tint and paints its label white whatever that
  /// tint is. The setup flow's Continue and submit buttons are the only prominent buttons that
  /// inherit `brandTint`, so the navy must carry white text, a stricter bar than the 3:1 the switch
  /// track needs.
  @Test("a prominent button's white label stays legible on the brand tint")
  func brandTintCarriesAWhiteLabel() {
    for style in [UIUserInterfaceStyle.light, .dark] {
      let ratio = contrastRatio(AppChrome.brandTint.resolved(style), WhirrRGBColor(1, 1, 1))
      #expect(ratio >= 4.5, "white prominent label vs brand tint in \(style)")
    }
  }
}

extension Color {
  fileprivate func resolved(_ style: UIUserInterfaceStyle) -> WhirrRGBColor {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    UIColor(self)
      .resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
      .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return WhirrRGBColor(Double(red), Double(green), Double(blue))
  }
}

extension WhirrRGBColor {
  fileprivate var isCloserToWhite: Bool {
    contrastRatio(self, WhirrRGBColor(1, 1, 1)) < contrastRatio(self, WhirrRGBColor(0, 0, 0))
  }
}

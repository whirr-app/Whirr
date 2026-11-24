import SnapshotTesting
import SwiftUI
import Testing

@testable import DesignSystem

@MainActor
extension ReaderComponentTests {
  // MARK: - Shared accessibility and palette contracts

  // MARK: - Chrome motion

  @Test("reader chrome motion suppresses the toolbar animation under reduce motion")
  func readerChromeMotionSuppressesBarSlideUnderReduceMotion() {
    #expect(ReaderChromeMotion.animation(reduceMotion: true) == nil)
    #expect(
      ReaderChromeMotion.animation(reduceMotion: false)
        == .smooth(duration: ReaderChromeMotion.duration))
  }

  @Test("reader chrome glass follows Reduce Transparency and Reduce Motion")
  func readerChromeGlassFollowsAccessibilityPreferences() {
    #expect(
      GlassEffectPolicy.decide(isGlassAvailable: true, prefersReducedTransparency: true)
        == GlassEffectDecision(usesGlass: false, reason: .reducedTransparency)
    )
    #expect(GlassContainer<EmptyView, RoundedRectangle>.transitionAnimation(reduceMotion: true) == nil)
    #expect(GlassContainer<EmptyView, RoundedRectangle>.transitionAnimation(reduceMotion: false) != nil)
  }

  @Test("reader palettes expose distinct semantic chrome roles", arguments: ReaderTheme.allCases)
  func readerPalettesExposeDistinctSemanticChromeRoles(theme: ReaderTheme) {
    let palette = theme.palette

    #expect(palette.divider != palette.track)
    #expect(palette.divider != palette.controlFill)
    #expect(palette.divider != palette.selectedControlFill)
    #expect(palette.track != palette.controlFill)
    #expect(palette.track != palette.selectedControlFill)
    #expect(palette.controlFill != palette.selectedControlFill)
  }

  @Test("reader palettes give divider and track the non-text contrast floor", arguments: ReaderTheme.allCases)
  func readerPalettesGiveDividerAndTrackNonTextContrast(theme: ReaderTheme) {
    let palette = theme.palette
    #expect(contrastRatio(palette.divider, palette.chromeBackground) >= 3)
    #expect(contrastRatio(palette.track, palette.chromeBackground) >= 3)
  }

  @Test("reader control fills remain distinguishable in grayscale", arguments: ReaderTheme.allCases)
  func readerControlFillsRemainDistinguishableInGrayscale(theme: ReaderTheme) {
    let palette = theme.palette
    let minimumControlSelectionContrast = 1.5

    #expect(contrastRatio(palette.controlFill, palette.selectedControlFill) >= minimumControlSelectionContrast)
  }

  @Test("light, sepia, and dark reader chrome palettes meet text contrast", arguments: ReaderTheme.allCases)
  func readerChromePalettesMeetTextContrast(theme: ReaderTheme) {
    let palette = theme.palette
    #expect(contrastRatio(palette.foreground, palette.background) >= 4.5)
    #expect(contrastRatio(palette.chromeForeground, palette.chromeBackground) >= 4.5)
    #expect(contrastRatio(palette.secondaryForeground, palette.background) >= 4.5)
    #expect(contrastRatio(palette.secondaryForeground, palette.chromeBackground) >= 4.5)
  }

  @Test("reader accents stay legible as text", arguments: ReaderTheme.allCases)
  func readerAccentsStayLegibleAsText(theme: ReaderTheme) {
    let palette = theme.palette
    // The accent carries the current chapter's title and page number, so it is text.
    #expect(contrastRatio(palette.accent, palette.background) >= 4.5)
    #expect(contrastRatio(palette.accent, palette.chromeBackground) >= 4.5)
  }

  @Test("the light reader accent is the app's own navy ink")
  func lightReaderAccentIsBrandInk() {
    // The app's controls are navy or plain; a gold switch in the reader read as a different app.
    #expect(ReaderTheme.light.palette.accent == WhirrColorToken.brandInk.lightRGB)
  }

  @Test("the sepia reader accent stays warm")
  func sepiaReaderAccentStaysWarm() {
    let accent = ReaderTheme.sepia.palette.accent
    // A blue-leaning accent on a warm page reads as another app's chrome.
    #expect(accent.red > accent.blue)
    #expect(accent.green > accent.blue)
  }

  @Test("the dark reader accent is a lifted navy, blue-led like the app's own")
  func darkReaderAccentIsLiftedNavy() {
    let accent = ReaderTheme.dark.palette.accent
    // Blue-led like the app's own navy.
    #expect(accent.blue > accent.green)
    #expect(accent.green > accent.red)
  }

  @Test("reader accents are muted, not a gold or orange highlight", arguments: ReaderTheme.allCases)
  func readerAccentsAreMuted(theme: ReaderTheme) {
    let accent = theme.palette.accent
    let spread =
      max(accent.red, accent.green, accent.blue) - min(accent.red, accent.green, accent.blue)
    // A gold (235, 204, 140) or orange (143, 91, 23) accent spreads 95 and 120 of 255.
    #expect(spread <= 92.0 / 255.0)
  }

  @Test("reader accents stand apart from the page's own text", arguments: ReaderTheme.allCases)
  func readerAccentsStandApartFromText(theme: ReaderTheme) {
    let palette = theme.palette
    // The accent marks the current chapter among rows drawn in the text colours.
    #expect(palette.accent != palette.foreground)
    #expect(palette.accent != palette.secondaryForeground)
  }
}

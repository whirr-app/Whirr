import SwiftUI

/// The reader's independent reading themes. Separate from the system light/dark appearance: sepia
/// is a reading surface, not a third system color scheme.
public enum ReaderTheme: String, CaseIterable, Identifiable, Sendable, Equatable {
  case light
  case sepia
  case dark

  public var id: Self { self }

  /// The complete palette for this reading theme, including the floating chrome surface.
  public var palette: ReaderThemePalette {
    switch self {
    case .light: return .light
    case .sepia: return .sepia
    case .dark: return .dark
    }
  }
}

/// Fixed sRGB values for the reader's content and floating chrome roles.
///
/// Reader chrome cannot use the system semantic colors alone: the reader theme can be sepia or
/// light while the system is dark. `WhirrRGBColor` keeps the contrast contract testable without a
/// renderer; the computed `Color` values are what SwiftUI consumes.
public struct ReaderThemePalette: Sendable, Equatable {
  public let background: WhirrRGBColor
  public let foreground: WhirrRGBColor
  public let secondaryForeground: WhirrRGBColor
  public let chromeBackground: WhirrRGBColor
  public let chromeForeground: WhirrRGBColor
  public let accent: WhirrRGBColor
  public let divider: WhirrRGBColor
  public let track: WhirrRGBColor
  public let controlFill: WhirrRGBColor
  public let selectedControlFill: WhirrRGBColor

  public init(
    background: WhirrRGBColor,
    foreground: WhirrRGBColor,
    secondaryForeground: WhirrRGBColor,
    chromeBackground: WhirrRGBColor,
    chromeForeground: WhirrRGBColor,
    accent: WhirrRGBColor,
    divider: WhirrRGBColor,
    track: WhirrRGBColor,
    controlFill: WhirrRGBColor,
    selectedControlFill: WhirrRGBColor
  ) {
    self.background = background
    self.foreground = foreground
    self.secondaryForeground = secondaryForeground
    self.chromeBackground = chromeBackground
    self.chromeForeground = chromeForeground
    self.accent = accent
    self.divider = divider
    self.track = track
    self.controlFill = controlFill
    self.selectedControlFill = selectedControlFill
  }

  /// The canvas behind a grouped list in this theme, and the card that sits on it. The system's
  /// grouped list always puts the lighter surface in the card, in dark mode as much as in light,
  /// so the two roles are picked by luminance rather than named per theme.
  public var groupedBackground: WhirrRGBColor {
    background.relativeLuminance <= chromeBackground.relativeLuminance ? background : chromeBackground
  }

  public var groupedRowBackground: WhirrRGBColor {
    background.relativeLuminance <= chromeBackground.relativeLuminance ? chromeBackground : background
  }

  public var groupedBackgroundColor: Color { groupedBackground.color }
  public var groupedRowBackgroundColor: Color { groupedRowBackground.color }

  public var backgroundColor: Color { background.color }
  public var foregroundColor: Color { foreground.color }
  public var secondaryForegroundColor: Color { secondaryForeground.color }
  public var chromeBackgroundColor: Color { chromeBackground.color }
  public var chromeForegroundColor: Color { chromeForeground.color }
  public var accentColor: Color { accent.color }
  public var dividerColor: Color { divider.color }
  public var trackColor: Color { track.color }
  public var controlFillColor: Color { controlFill.color }
  public var selectedControlFillColor: Color { selectedControlFill.color }

  /// The four docked-chrome roles, solved from their designed values against the surface each one
  /// actually sits on.
  ///
  /// `divider`, `track` and `controlFill` answer to the chrome directly and each meet the 3:1 of
  /// WCAG SC 1.4.11 for a graphical object (they show where a control or the docked bar is).
  ///
  /// `selectedControlFill` is solved for two constraints in turn: 3:1 against the chrome, then 1.6
  /// against the idle fill, since telling selected from idle is what the state communicates. The
  /// second solve moves away from the idle fill, which on every theme is further from the chrome,
  /// so neither solve undoes the other.
  private struct ChromeRoles {
    let divider: WhirrRGBColor
    let track: WhirrRGBColor
    let controlFill: WhirrRGBColor
    let selectedControlFill: WhirrRGBColor

    init(
      chrome: WhirrRGBColor,
      divider: WhirrRGBColor,
      track: WhirrRGBColor,
      controlFill: WhirrRGBColor,
      selectedControlFill: WhirrRGBColor
    ) {
      self.divider = nonTextContrastColor(preferred: divider, on: chrome)
      self.track = nonTextContrastColor(preferred: track, on: chrome)
      let idle = nonTextContrastColor(preferred: controlFill, on: chrome)
      self.controlFill = idle
      self.selectedControlFill = nonTextContrastColor(
        preferred: nonTextContrastColor(preferred: selectedControlFill, on: chrome),
        on: idle,
        minimumRatio: 1.6)
    }
  }

  private static let lightRoles = ChromeRoles(
    chrome: WhirrRGBColor(245.0 / 255.0, 246.0 / 255.0, 244.0 / 255.0),
    divider: WhirrRGBColor(217.0 / 255.0, 222.0 / 255.0, 226.0 / 255.0),
    track: WhirrRGBColor(201.0 / 255.0, 208.0 / 255.0, 213.0 / 255.0),
    controlFill: WhirrRGBColor(238.0 / 255.0, 240.0 / 255.0, 241.0 / 255.0),
    selectedControlFill: WhirrRGBColor(181.0 / 255.0, 190.0 / 255.0, 199.0 / 255.0))

  private static let sepiaRoles = ChromeRoles(
    chrome: WhirrRGBColor(247.0 / 255.0, 233.0 / 255.0, 204.0 / 255.0),
    divider: WhirrRGBColor(217.0 / 255.0, 198.0 / 255.0, 166.0 / 255.0),
    track: WhirrRGBColor(201.0 / 255.0, 178.0 / 255.0, 140.0 / 255.0),
    controlFill: WhirrRGBColor(240.0 / 255.0, 223.0 / 255.0, 192.0 / 255.0),
    selectedControlFill: WhirrRGBColor(193.0 / 255.0, 155.0 / 255.0, 99.0 / 255.0))

  private static let darkRoles = ChromeRoles(
    chrome: WhirrRGBColor(23.0 / 255.0, 26.0 / 255.0, 28.0 / 255.0),
    divider: WhirrRGBColor(60.0 / 255.0, 64.0 / 255.0, 63.0 / 255.0),
    track: WhirrRGBColor(69.0 / 255.0, 74.0 / 255.0, 73.0 / 255.0),
    controlFill: WhirrRGBColor(34.0 / 255.0, 38.0 / 255.0, 40.0 / 255.0),
    selectedControlFill: WhirrRGBColor(75.0 / 255.0, 81.0 / 255.0, 79.0 / 255.0))

  public static let light = ReaderThemePalette(
    background: WhirrRGBColor(251.0 / 255.0, 251.0 / 255.0, 249.0 / 255.0),
    foreground: WhirrRGBColor(21.0 / 255.0, 23.0 / 255.0, 25.0 / 255.0),
    secondaryForeground: WhirrRGBColor(91.0 / 255.0, 98.0 / 255.0, 106.0 / 255.0),
    chromeBackground: WhirrRGBColor(245.0 / 255.0, 246.0 / 255.0, 244.0 / 255.0),
    chromeForeground: WhirrRGBColor(21.0 / 255.0, 23.0 / 255.0, 25.0 / 255.0),
    // The app's own navy ink, so the reader's controls match the rest of the app's. The accent
    // also carries text (the current chapter's title and page number) and this clears 4.5:1.
    accent: WhirrColorToken.brandInk.lightRGB,
    divider: lightRoles.divider,
    track: lightRoles.track,
    controlFill: lightRoles.controlFill,
    selectedControlFill: lightRoles.selectedControlFill
  )

  public static let sepia = ReaderThemePalette(
    background: WhirrRGBColor(255.0 / 255.0, 244.0 / 255.0, 223.0 / 255.0),
    foreground: WhirrRGBColor(61.0 / 255.0, 43.0 / 255.0, 31.0 / 255.0),
    secondaryForeground: WhirrRGBColor(110.0 / 255.0, 82.0 / 255.0, 57.0 / 255.0),
    chromeBackground: WhirrRGBColor(247.0 / 255.0, 233.0 / 255.0, 204.0 / 255.0),
    chromeForeground: WhirrRGBColor(61.0 / 255.0, 43.0 / 255.0, 31.0 / 255.0),
    // A deep russet from the page's own browns, darker and less orange than a highlight colour.
    accent: WhirrRGBColor(122.0 / 255.0, 72.0 / 255.0, 32.0 / 255.0),
    divider: sepiaRoles.divider,
    track: sepiaRoles.track,
    controlFill: sepiaRoles.controlFill,
    selectedControlFill: sepiaRoles.selectedControlFill
  )

  public static let dark = ReaderThemePalette(
    // True black rather than the app's dark page: on an OLED panel any lift shows in a dark room.
    background: WhirrRGBColor(0, 0, 0),
    foreground: WhirrRGBColor(244.0 / 255.0, 240.0 / 255.0, 232.0 / 255.0),
    secondaryForeground: WhirrRGBColor(184.0 / 255.0, 180.0 / 255.0, 172.0 / 255.0),
    chromeBackground: WhirrRGBColor(23.0 / 255.0, 26.0 / 255.0, 28.0 / 255.0),
    chromeForeground: WhirrRGBColor(244.0 / 255.0, 240.0 / 255.0, 232.0 / 255.0),
    // The app's navy, lifted for a near-black page: the same hue as the dark-appearance brand tint
    // but bright enough to carry the chapter title as text (4.5:1) as well as the rail's fill.
    accent: WhirrRGBColor(110.0 / 255.0, 143.0 / 255.0, 180.0 / 255.0),
    divider: darkRoles.divider,
    track: darkRoles.track,
    controlFill: darkRoles.controlFill,
    selectedControlFill: darkRoles.selectedControlFill
  )
}

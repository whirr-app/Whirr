import Foundation

/// The concrete typography a set of reader preferences asks for.
///
/// The single step-to-value mapping: the Readium adapter and the appearance sample both use it,
/// so the sample cannot drift from the page. Spacing is in em; `nil` leaves the publication's own.
public struct ReaderTypography: Equatable, Sendable {
  /// A multiplier on the publication's font size.
  public let fontScale: Double
  /// A multiplier on the font size, as CSS `line-height`.
  public let lineHeight: Double
  /// A multiplier on ReadiumCSS's default horizontal page margin.
  public let pageMargins: Double
  public let wordSpacing: Double?
  public let letterSpacing: Double?
  public let paragraphSpacing: Double?

  public init(preferences: ReaderPreferences) {
    fontScale = 1.0 + Double(preferences.fontSizeStep) * 0.125
    lineHeight = 1.0 + Double(preferences.lineSpacingStep) * 0.1
    pageMargins = 1.0 + Double(preferences.marginsStep) * 0.25
    wordSpacing = Self.spacing(step: preferences.wordSpacingStep, multiplier: 0.25)
    letterSpacing = Self.spacing(step: preferences.letterSpacingStep, multiplier: 0.25)
    paragraphSpacing = Self.spacing(step: preferences.paragraphSpacingStep, multiplier: 0.5)
  }

  private static func spacing(step: Int, multiplier: Double) -> Double? {
    step == 0 ? nil : Double(step) * multiplier
  }
}

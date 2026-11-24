import SwiftUI

/// Reader appearance controls backed entirely by caller-owned bindings.
///
/// `isReflowable` is a capability value from the reader session, not internal state. When it is
/// false, every control that would change reflow is disabled and carries the caller's unavailable
/// announcement. The theme remains available because it is meaningful for fixed-layout content.
public struct ReaderAppearanceControls: View {
  public static let bodyTextToken: WhirrTypeToken = .body
  public static let sectionTextToken: WhirrTypeToken = .caption
  /// The glyph a menu-backed row carries on its trailing edge, matching a system menu picker.
  public static let menuIndicatorSystemImage = "chevron.up.chevron.down"

  public static let fontRowIdentifierSuffix = "font"
  public static let fontSizeIdentifierSuffix = "fontSize"
  public static let themesIdentifierSuffix = "themes"
  public static let brightnessIdentifierSuffix = "brightness"
  public static let layoutIdentifierSuffix = "layout"
  public static let lineSpacingIdentifierSuffix = "lineSpacing"
  public static let wordSpacingIdentifierSuffix = "wordSpacing"
  public static let letterSpacingIdentifierSuffix = "letterSpacing"
  public static let paragraphSpacingIdentifierSuffix = "paragraphSpacing"
  public static let hyphenationIdentifierSuffix = "hyphenation"
  public static let publisherStylesIdentifierSuffix = "publisherStyles"
  public static let marginsIdentifierSuffix = "margins"
  public static let readingModeIdentifierSuffix = "readingMode"
  public static let customiseIdentifierSuffix = "customise"
  public static let sampleIdentifierSuffix = "sample"
  public static let resetIdentifierSuffix = "reset"

  @Binding public var theme: ReaderTheme
  public let themeOptions: [ReaderThemeOption]
  public let themeLabel: String
  public let themeAccessibilityLabel: String

  /// The optional binding is also the capability gate: when the App cannot capture a screen,
  /// the panel has no brightness row at all rather than a disabled-looking dead control.
  public let brightness: Binding<Double>?
  public let brightnessLabel: String
  public let brightnessAccessibilityLabel: String
  public let brightnessValue: String

  @Binding public var fontFamily: ReaderFontFamily
  public let fontFamilyOptions: [ReaderFontFamilyOption]
  public let fontLabel: String
  public let fontFamilyAccessibilityLabel: String

  @Binding public var fontSize: Double
  public let fontSizeRange: ClosedRange<Double>
  public let fontSizeStep: Double
  public let fontSizeLabel: String
  public let fontSizeAccessibilityLabel: String
  public let fontSizeAccessibilityValue: String
  public let fontSizeDecrement: ReaderAppearanceCellLabel
  public let fontSizeIncrement: ReaderAppearanceCellLabel

  @Binding public var publisherStyles: Bool
  public let publisherStylesLabel: String
  public let publisherStylesAccessibilityLabel: String
  public let publisherStylesOnValue: String
  public let publisherStylesOffValue: String

  @Binding public var alignment: ReaderTextAlignment
  public let alignmentOptions: [ReaderTextAlignmentOption]
  public let layoutLabel: String
  public let alignmentAccessibilityLabel: String

  @Binding public var lineSpacing: Double
  public let lineSpacingRange: ClosedRange<Double>
  public let lineSpacingStep: Double
  public let lineSpacingLabel: String
  public let lineSpacingAccessibilityLabel: String
  public let lineSpacingAccessibilityValue: String
  public let lineSpacingDecrement: ReaderAppearanceCellLabel
  public let lineSpacingIncrement: ReaderAppearanceCellLabel

  @Binding public var wordSpacing: Double
  public let wordSpacingRange: ClosedRange<Double>
  public let wordSpacingStep: Double
  public let wordSpacingLabel: String
  public let wordSpacingAccessibilityLabel: String
  public let wordSpacingAccessibilityValue: String
  public let wordSpacingDecrement: ReaderAppearanceCellLabel
  public let wordSpacingIncrement: ReaderAppearanceCellLabel

  @Binding public var letterSpacing: Double
  public let letterSpacingRange: ClosedRange<Double>
  public let letterSpacingStep: Double
  public let letterSpacingLabel: String
  public let letterSpacingAccessibilityLabel: String
  public let letterSpacingAccessibilityValue: String
  public let letterSpacingDecrement: ReaderAppearanceCellLabel
  public let letterSpacingIncrement: ReaderAppearanceCellLabel

  @Binding public var paragraphSpacing: Double
  public let paragraphSpacingRange: ClosedRange<Double>
  public let paragraphSpacingStep: Double
  public let paragraphSpacingLabel: String
  public let paragraphSpacingAccessibilityLabel: String
  public let paragraphSpacingAccessibilityValue: String
  public let paragraphSpacingDecrement: ReaderAppearanceCellLabel
  public let paragraphSpacingIncrement: ReaderAppearanceCellLabel

  @Binding public var hyphenation: Bool
  public let hyphenationLabel: String
  public let hyphenationAccessibilityLabel: String
  public let hyphenationOnValue: String
  public let hyphenationOffValue: String

  @Binding public var margins: Double
  public let marginsRange: ClosedRange<Double>
  public let marginsStep: Double
  public let marginsLabel: String
  public let marginsAccessibilityLabel: String
  public let marginsAccessibilityValue: String
  public let marginsDecrement: ReaderAppearanceCellLabel
  public let marginsIncrement: ReaderAppearanceCellLabel

  @Binding public var isScrollMode: Bool
  public let paginatedLabel: String
  public let scrollLabel: String
  public let readingModeAccessibilityLabel: String

  public let isReflowable: Bool
  public let disabledAccessibilityValue: String
  public let typographyLabel: String
  public let publisherStylesFooter: String
  public let customiseLabel: String
  /// Which page of the panel this instance draws. The customise page is pushed from the
  /// essentials page's customise row, with this type's `ReaderAppearanceLevel` as the value.
  public let level: ReaderAppearanceLevel
  /// The live typography sample pinned above the customise page's rows. The App draws it, because
  /// it is set from the reader's own typography mapping and the open book's text.
  public let sample: AnyView?
  public let resetLabel: String
  /// Resets typography only; `nil` leaves the customise page without a reset row.
  public let onReset: (() -> Void)?
  /// App-supplied namespace for per-control identifiers. The suffixes are structural, not copy, so
  /// they live here while the namespace stays with the caller.
  public let identifierPrefix: String?

  public init(
    theme: Binding<ReaderTheme>,
    themeOptions: [ReaderThemeOption],
    themeLabel: String,
    themeAccessibilityLabel: String,
    fontFamily: Binding<ReaderFontFamily>,
    fontFamilyOptions: [ReaderFontFamilyOption],
    fontLabel: String,
    fontFamilyAccessibilityLabel: String,
    fontSize: Binding<Double>,
    fontSizeRange: ClosedRange<Double>,
    fontSizeStep: Double,
    fontSizeLabel: String,
    fontSizeAccessibilityLabel: String,
    fontSizeAccessibilityValue: String,
    fontSizeDecrement: ReaderAppearanceCellLabel,
    fontSizeIncrement: ReaderAppearanceCellLabel,
    publisherStyles: Binding<Bool>,
    publisherStylesLabel: String,
    publisherStylesAccessibilityLabel: String,
    publisherStylesOnValue: String,
    publisherStylesOffValue: String,
    alignment: Binding<ReaderTextAlignment>,
    alignmentOptions: [ReaderTextAlignmentOption],
    layoutLabel: String,
    alignmentAccessibilityLabel: String,
    lineSpacing: Binding<Double>,
    lineSpacingRange: ClosedRange<Double>,
    lineSpacingStep: Double,
    lineSpacingLabel: String,
    lineSpacingAccessibilityLabel: String,
    lineSpacingAccessibilityValue: String,
    lineSpacingDecrement: ReaderAppearanceCellLabel,
    lineSpacingIncrement: ReaderAppearanceCellLabel,
    wordSpacing: Binding<Double>,
    wordSpacingRange: ClosedRange<Double>,
    wordSpacingStep: Double,
    wordSpacingLabel: String,
    wordSpacingAccessibilityLabel: String,
    wordSpacingAccessibilityValue: String,
    wordSpacingDecrement: ReaderAppearanceCellLabel,
    wordSpacingIncrement: ReaderAppearanceCellLabel,
    letterSpacing: Binding<Double>,
    letterSpacingRange: ClosedRange<Double>,
    letterSpacingStep: Double,
    letterSpacingLabel: String,
    letterSpacingAccessibilityLabel: String,
    letterSpacingAccessibilityValue: String,
    letterSpacingDecrement: ReaderAppearanceCellLabel,
    letterSpacingIncrement: ReaderAppearanceCellLabel,
    paragraphSpacing: Binding<Double>,
    paragraphSpacingRange: ClosedRange<Double>,
    paragraphSpacingStep: Double,
    paragraphSpacingLabel: String,
    paragraphSpacingAccessibilityLabel: String,
    paragraphSpacingAccessibilityValue: String,
    paragraphSpacingDecrement: ReaderAppearanceCellLabel,
    paragraphSpacingIncrement: ReaderAppearanceCellLabel,
    hyphenation: Binding<Bool>,
    hyphenationLabel: String,
    hyphenationAccessibilityLabel: String,
    hyphenationOnValue: String,
    hyphenationOffValue: String,
    margins: Binding<Double>,
    marginsRange: ClosedRange<Double>,
    marginsStep: Double,
    marginsLabel: String,
    marginsAccessibilityLabel: String,
    marginsAccessibilityValue: String,
    marginsDecrement: ReaderAppearanceCellLabel,
    marginsIncrement: ReaderAppearanceCellLabel,
    isScrollMode: Binding<Bool>,
    paginatedLabel: String,
    scrollLabel: String,
    readingModeAccessibilityLabel: String,
    isReflowable: Bool,
    disabledAccessibilityValue: String,
    typographyLabel: String,
    publisherStylesFooter: String,
    brightness: Binding<Double>? = nil,
    brightnessLabel: String = "",
    brightnessAccessibilityLabel: String = "",
    brightnessValue: String = "",
    customiseLabel: String = "",
    level: ReaderAppearanceLevel = .essentials,
    sample: AnyView? = nil,
    resetLabel: String = "",
    onReset: (() -> Void)? = nil,
    identifierPrefix: String? = nil
  ) {
    self._theme = theme
    self.themeOptions = themeOptions
    self.themeLabel = themeLabel
    self.themeAccessibilityLabel = themeAccessibilityLabel
    self.brightness = brightness
    self.brightnessLabel = brightnessLabel
    self.brightnessAccessibilityLabel = brightnessAccessibilityLabel
    self.brightnessValue = brightnessValue
    self._fontFamily = fontFamily
    self.fontFamilyOptions = fontFamilyOptions
    self.fontLabel = fontLabel
    self.fontFamilyAccessibilityLabel = fontFamilyAccessibilityLabel
    self._fontSize = fontSize
    self.fontSizeRange = fontSizeRange
    self.fontSizeStep = fontSizeStep
    self.fontSizeLabel = fontSizeLabel
    self.fontSizeAccessibilityLabel = fontSizeAccessibilityLabel
    self.fontSizeAccessibilityValue = fontSizeAccessibilityValue
    self.fontSizeDecrement = fontSizeDecrement
    self.fontSizeIncrement = fontSizeIncrement
    self._publisherStyles = publisherStyles
    self.publisherStylesLabel = publisherStylesLabel
    self.publisherStylesAccessibilityLabel = publisherStylesAccessibilityLabel
    self.publisherStylesOnValue = publisherStylesOnValue
    self.publisherStylesOffValue = publisherStylesOffValue
    self._alignment = alignment
    self.alignmentOptions = alignmentOptions
    self.layoutLabel = layoutLabel
    self.alignmentAccessibilityLabel = alignmentAccessibilityLabel
    self._lineSpacing = lineSpacing
    self.lineSpacingRange = lineSpacingRange
    self.lineSpacingStep = lineSpacingStep
    self.lineSpacingLabel = lineSpacingLabel
    self.lineSpacingAccessibilityLabel = lineSpacingAccessibilityLabel
    self.lineSpacingAccessibilityValue = lineSpacingAccessibilityValue
    self.lineSpacingDecrement = lineSpacingDecrement
    self.lineSpacingIncrement = lineSpacingIncrement
    self._wordSpacing = wordSpacing
    self.wordSpacingRange = wordSpacingRange
    self.wordSpacingStep = wordSpacingStep
    self.wordSpacingLabel = wordSpacingLabel
    self.wordSpacingAccessibilityLabel = wordSpacingAccessibilityLabel
    self.wordSpacingAccessibilityValue = wordSpacingAccessibilityValue
    self.wordSpacingDecrement = wordSpacingDecrement
    self.wordSpacingIncrement = wordSpacingIncrement
    self._letterSpacing = letterSpacing
    self.letterSpacingRange = letterSpacingRange
    self.letterSpacingStep = letterSpacingStep
    self.letterSpacingLabel = letterSpacingLabel
    self.letterSpacingAccessibilityLabel = letterSpacingAccessibilityLabel
    self.letterSpacingAccessibilityValue = letterSpacingAccessibilityValue
    self.letterSpacingDecrement = letterSpacingDecrement
    self.letterSpacingIncrement = letterSpacingIncrement
    self._paragraphSpacing = paragraphSpacing
    self.paragraphSpacingRange = paragraphSpacingRange
    self.paragraphSpacingStep = paragraphSpacingStep
    self.paragraphSpacingLabel = paragraphSpacingLabel
    self.paragraphSpacingAccessibilityLabel = paragraphSpacingAccessibilityLabel
    self.paragraphSpacingAccessibilityValue = paragraphSpacingAccessibilityValue
    self.paragraphSpacingDecrement = paragraphSpacingDecrement
    self.paragraphSpacingIncrement = paragraphSpacingIncrement
    self._hyphenation = hyphenation
    self.hyphenationLabel = hyphenationLabel
    self.hyphenationAccessibilityLabel = hyphenationAccessibilityLabel
    self.hyphenationOnValue = hyphenationOnValue
    self.hyphenationOffValue = hyphenationOffValue
    self._margins = margins
    self.marginsRange = marginsRange
    self.marginsStep = marginsStep
    self.marginsLabel = marginsLabel
    self.marginsAccessibilityLabel = marginsAccessibilityLabel
    self.marginsAccessibilityValue = marginsAccessibilityValue
    self.marginsDecrement = marginsDecrement
    self.marginsIncrement = marginsIncrement
    self._isScrollMode = isScrollMode
    self.paginatedLabel = paginatedLabel
    self.scrollLabel = scrollLabel
    self.readingModeAccessibilityLabel = readingModeAccessibilityLabel
    self.isReflowable = isReflowable
    self.disabledAccessibilityValue = disabledAccessibilityValue
    self.typographyLabel = typographyLabel
    self.publisherStylesFooter = publisherStylesFooter
    self.customiseLabel = customiseLabel
    self.level = level
    self.sample = sample
    self.resetLabel = resetLabel
    self.onReset = onReset
    self.identifierPrefix = identifierPrefix
  }
}

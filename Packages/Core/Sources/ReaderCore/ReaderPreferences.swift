import Foundation

/// The reading surface theme. `.system` is the initial choice; the other cases are independent
/// of the app window's system color scheme.
public enum ReaderTheme: String, CaseIterable, Codable, Equatable, Sendable {
  case system
  case light
  case sepia
  case dark
}

/// The app-owned font choices exposed to the reader. `publisherDefault` leaves the publication's
/// own font choice in control; `publisher` is a source-compatible spelling for callers that use
/// the shorter UI label.
public enum ReaderFontFamily: String, CaseIterable, Codable, Equatable, Sendable {
  case publisherDefault
  case serif
  case sansSerif
  case monospaced
  case openDyslexic

  public static var publisher: Self { .publisherDefault }
}

/// The app-owned text-alignment choices exposed to the reader. `.publisherDefault` leaves the
/// publication's own CSS in control.
public enum ReaderTextAlignment: String, CaseIterable, Codable, Equatable, Sendable {
  case publisherDefault
  case left
  case justify
}

/// Whether reflowable content is shown as CSS columns or one continuous scroll surface.
public enum ReaderReadingMode: String, Codable, Equatable, Sendable {
  case paginated
  case scroll
}

/// What the running footer in the page's bottom margin reads. The cases are in the order a tap on
/// the footer steps through them.
public enum ReaderFooterReadout: String, CaseIterable, Codable, Equatable, Sendable {
  case page
  case chapterTimeLeft
  case percent
}

/// Local reader presentation settings, independent of Readium's preference API.
public struct ReaderPreferences: Codable, Equatable, Sendable {
  /// Relative font-size adjustments: the default is the publisher size, with eight positive steps.
  public static let fontSizeStepBounds: ClosedRange<Int> = 0...8
  /// Relative line-spacing adjustments: zero is the initial publication spacing.
  public static let lineSpacingStepBounds: ClosedRange<Int> = 0...4
  /// Relative horizontal-margin adjustments: zero is the initial publication margin.
  public static let marginsStepBounds: ClosedRange<Int> = 0...4
  /// Relative word-spacing adjustments: zero is the initial publication spacing.
  public static let wordSpacingStepBounds: ClosedRange<Int> = 0...4
  /// Relative letter-spacing adjustments: zero is the initial publication spacing.
  public static let letterSpacingStepBounds: ClosedRange<Int> = 0...4
  /// Relative paragraph-spacing adjustments: zero is the initial publication spacing.
  public static let paragraphSpacingStepBounds: ClosedRange<Int> = 0...4

  public static let defaultFontSizeStep = 0
  public static let defaultLineSpacingStep = 0
  public static let defaultMarginsStep = 0
  public static let defaultWordSpacingStep = 0
  public static let defaultLetterSpacingStep = 0
  public static let defaultParagraphSpacingStep = 0
  public static let defaultHyphenation = false
  public static let defaultPublisherStyles = true

  public var theme: ReaderTheme
  public var fontFamily: ReaderFontFamily
  public var fontSizeStep: Int {
    didSet { fontSizeStep = Self.clamp(fontSizeStep, to: Self.fontSizeStepBounds) }
  }
  public var lineSpacingStep: Int {
    didSet { lineSpacingStep = Self.clamp(lineSpacingStep, to: Self.lineSpacingStepBounds) }
  }
  public var marginsStep: Int {
    didSet { marginsStep = Self.clamp(marginsStep, to: Self.marginsStepBounds) }
  }
  public var readingMode: ReaderReadingMode
  public var textAlignment: ReaderTextAlignment
  public var wordSpacingStep: Int {
    didSet { wordSpacingStep = Self.clamp(wordSpacingStep, to: Self.wordSpacingStepBounds) }
  }
  public var letterSpacingStep: Int {
    didSet { letterSpacingStep = Self.clamp(letterSpacingStep, to: Self.letterSpacingStepBounds) }
  }
  public var paragraphSpacingStep: Int {
    didSet {
      paragraphSpacingStep = Self.clamp(
        paragraphSpacingStep,
        to: Self.paragraphSpacingStepBounds)
    }
  }
  public var hyphenation: Bool
  public var publisherStyles: Bool
  public var footerReadout: ReaderFooterReadout

  /// Renderer capability, not a user preference. Reflow controls are available only when true.
  public let reflowable: Bool

  public var fixedLayout: Bool { reflowable == false }
  public var isReflowable: Bool { reflowable }
  public var isScrollMode: Bool { readingMode == .scroll }

  public init(
    theme: ReaderTheme = .system,
    fontFamily: ReaderFontFamily = .publisherDefault,
    fontSizeStep: Int = Self.defaultFontSizeStep,
    lineSpacingStep: Int = Self.defaultLineSpacingStep,
    marginsStep: Int = Self.defaultMarginsStep,
    readingMode: ReaderReadingMode = .paginated,
    textAlignment: ReaderTextAlignment = .publisherDefault,
    wordSpacingStep: Int = Self.defaultWordSpacingStep,
    letterSpacingStep: Int = Self.defaultLetterSpacingStep,
    paragraphSpacingStep: Int = Self.defaultParagraphSpacingStep,
    hyphenation: Bool = Self.defaultHyphenation,
    publisherStyles: Bool = Self.defaultPublisherStyles,
    footerReadout: ReaderFooterReadout = .page,
    reflowable: Bool = true
  ) {
    self.theme = theme
    self.fontFamily = fontFamily
    self.fontSizeStep = Self.clamp(fontSizeStep, to: Self.fontSizeStepBounds)
    self.lineSpacingStep = Self.clamp(lineSpacingStep, to: Self.lineSpacingStepBounds)
    self.marginsStep = Self.clamp(marginsStep, to: Self.marginsStepBounds)
    self.readingMode = readingMode
    self.textAlignment = textAlignment
    self.wordSpacingStep = Self.clamp(wordSpacingStep, to: Self.wordSpacingStepBounds)
    self.letterSpacingStep = Self.clamp(letterSpacingStep, to: Self.letterSpacingStepBounds)
    self.paragraphSpacingStep = Self.clamp(
      paragraphSpacingStep,
      to: Self.paragraphSpacingStepBounds)
    self.hyphenation = hyphenation
    self.publisherStyles = publisherStyles
    self.footerReadout = footerReadout
    self.reflowable = reflowable
  }

  public init(
    theme: ReaderTheme = .system,
    fontFamily: ReaderFontFamily = .publisherDefault,
    fontSizeStep: Int = Self.defaultFontSizeStep,
    lineSpacingStep: Int = Self.defaultLineSpacingStep,
    marginsStep: Int = Self.defaultMarginsStep,
    readingMode: ReaderReadingMode = .paginated,
    textAlignment: ReaderTextAlignment = .publisherDefault,
    wordSpacingStep: Int = Self.defaultWordSpacingStep,
    letterSpacingStep: Int = Self.defaultLetterSpacingStep,
    paragraphSpacingStep: Int = Self.defaultParagraphSpacingStep,
    hyphenation: Bool = Self.defaultHyphenation,
    publisherStyles: Bool = Self.defaultPublisherStyles,
    footerReadout: ReaderFooterReadout = .page,
    fixedLayout: Bool
  ) {
    self.init(
      theme: theme,
      fontFamily: fontFamily,
      fontSizeStep: fontSizeStep,
      lineSpacingStep: lineSpacingStep,
      marginsStep: marginsStep,
      readingMode: readingMode,
      textAlignment: textAlignment,
      wordSpacingStep: wordSpacingStep,
      letterSpacingStep: letterSpacingStep,
      paragraphSpacingStep: paragraphSpacingStep,
      hyphenation: hyphenation,
      publisherStyles: publisherStyles,
      footerReadout: footerReadout,
      reflowable: fixedLayout == false
    )
  }

  /// The appearance panel's reset: every typography and layout choice back to the publication's
  /// own, keeping the reader's theme, reading mode and footer readout, which are not typography.
  public func resettingTypography() -> ReaderPreferences {
    ReaderPreferences(
      theme: theme, readingMode: readingMode, footerReadout: footerReadout,
      reflowable: reflowable)
  }

  public mutating func incrementFontSizeStep() {
    fontSizeStep = min(Self.fontSizeStepBounds.upperBound, fontSizeStep + 1)
  }

  public mutating func decrementFontSizeStep() {
    fontSizeStep = max(Self.fontSizeStepBounds.lowerBound, fontSizeStep - 1)
  }

  public mutating func incrementLineSpacingStep() {
    lineSpacingStep = min(Self.lineSpacingStepBounds.upperBound, lineSpacingStep + 1)
  }

  public mutating func decrementLineSpacingStep() {
    lineSpacingStep = max(Self.lineSpacingStepBounds.lowerBound, lineSpacingStep - 1)
  }

  public mutating func incrementWordSpacingStep() {
    wordSpacingStep = min(Self.wordSpacingStepBounds.upperBound, wordSpacingStep + 1)
  }

  public mutating func decrementWordSpacingStep() {
    wordSpacingStep = max(Self.wordSpacingStepBounds.lowerBound, wordSpacingStep - 1)
  }

  public mutating func incrementLetterSpacingStep() {
    letterSpacingStep = min(Self.letterSpacingStepBounds.upperBound, letterSpacingStep + 1)
  }

  public mutating func decrementLetterSpacingStep() {
    letterSpacingStep = max(Self.letterSpacingStepBounds.lowerBound, letterSpacingStep - 1)
  }

  public mutating func incrementParagraphSpacingStep() {
    paragraphSpacingStep = min(
      Self.paragraphSpacingStepBounds.upperBound,
      paragraphSpacingStep + 1)
  }

  public mutating func decrementParagraphSpacingStep() {
    paragraphSpacingStep = max(
      Self.paragraphSpacingStepBounds.lowerBound,
      paragraphSpacingStep - 1)
  }

  public mutating func incrementMarginsStep() {
    marginsStep = min(Self.marginsStepBounds.upperBound, marginsStep + 1)
  }

  public mutating func decrementMarginsStep() {
    marginsStep = max(Self.marginsStepBounds.lowerBound, marginsStep - 1)
  }

  private enum CodingKeys: String, CodingKey {
    case theme
    case fontFamily
    case fontSizeStep
    case lineSpacingStep
    case marginsStep
    case readingMode
    case textAlignment
    case wordSpacingStep
    case letterSpacingStep
    case paragraphSpacingStep
    case hyphenation
    case publisherStyles
    case footerReadout
    case reflowable
    case fixedLayout
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let lineSpacingStep =
      (try? container.decode(Int.self, forKey: .lineSpacingStep))
      ?? Self.defaultLineSpacingStep
    let textAlignment =
      (try? container.decode(ReaderTextAlignment.self, forKey: .textAlignment))
      ?? .publisherDefault
    // Legacy payloads omitted publisherStyles, so infer the old alignment/line-spacing rule only
    // when the key is absent; a present value is authoritative, including explicit true.
    let publisherStyles: Bool
    if container.contains(.publisherStyles) {
      publisherStyles =
        (try? container.decode(Bool.self, forKey: .publisherStyles))
        ?? Self.defaultPublisherStyles
    } else {
      publisherStyles = !(textAlignment != .publisherDefault || lineSpacingStep > 0)
    }
    self.init(
      theme: (try? container.decode(ReaderTheme.self, forKey: .theme)) ?? .system,
      fontFamily: (try? container.decode(ReaderFontFamily.self, forKey: .fontFamily))
        ?? .publisherDefault,
      fontSizeStep: (try? container.decode(Int.self, forKey: .fontSizeStep))
        ?? Self.defaultFontSizeStep,
      lineSpacingStep: lineSpacingStep,
      marginsStep: (try? container.decode(Int.self, forKey: .marginsStep))
        ?? Self.defaultMarginsStep,
      readingMode: (try? container.decode(ReaderReadingMode.self, forKey: .readingMode))
        ?? .paginated,
      textAlignment: textAlignment,
      wordSpacingStep: (try? container.decode(Int.self, forKey: .wordSpacingStep))
        ?? Self.defaultWordSpacingStep,
      letterSpacingStep: (try? container.decode(Int.self, forKey: .letterSpacingStep))
        ?? Self.defaultLetterSpacingStep,
      paragraphSpacingStep: (try? container.decode(Int.self, forKey: .paragraphSpacingStep))
        ?? Self.defaultParagraphSpacingStep,
      hyphenation: (try? container.decode(Bool.self, forKey: .hyphenation))
        ?? Self.defaultHyphenation,
      publisherStyles: publisherStyles,
      footerReadout: (try? container.decode(ReaderFooterReadout.self, forKey: .footerReadout))
        ?? .page,
      reflowable: (try? container.decode(Bool.self, forKey: .reflowable))
        ?? ((try? container.decode(Bool.self, forKey: .fixedLayout)).map { $0 == false } ?? true)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(theme, forKey: .theme)
    try container.encode(fontFamily, forKey: .fontFamily)
    try container.encode(fontSizeStep, forKey: .fontSizeStep)
    try container.encode(lineSpacingStep, forKey: .lineSpacingStep)
    try container.encode(marginsStep, forKey: .marginsStep)
    try container.encode(readingMode, forKey: .readingMode)
    try container.encode(textAlignment, forKey: .textAlignment)
    try container.encode(wordSpacingStep, forKey: .wordSpacingStep)
    try container.encode(letterSpacingStep, forKey: .letterSpacingStep)
    try container.encode(paragraphSpacingStep, forKey: .paragraphSpacingStep)
    try container.encode(hyphenation, forKey: .hyphenation)
    try container.encode(publisherStyles, forKey: .publisherStyles)
    try container.encode(footerReadout, forKey: .footerReadout)
    try container.encode(reflowable, forKey: .reflowable)
  }

  private static func clamp(_ value: Int, to bounds: ClosedRange<Int>) -> Int {
    min(max(value, bounds.lowerBound), bounds.upperBound)
  }
}

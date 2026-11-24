import SwiftUI

/// Font families exposed by the reader. The labels remain caller-owned because the reader's
/// localized terminology belongs above DesignSystem.
public enum ReaderFontFamily: String, CaseIterable, Identifiable, Sendable, Equatable {
  case publisher
  case serif
  case sansSerif
  case monospaced
  case openDyslexic

  public var id: Self { self }

  var sampleFont: Font {
    switch self {
    case .publisher: return .body
    case .serif: return .system(.body, design: .serif)
    case .sansSerif: return .system(.body, design: .default)
    case .monospaced: return .system(.body, design: .monospaced)
    // The real face ships inside ReadiumNavigator's bundle and is only available to the
    // publication's web view, so the menu row must not pretend to preview it.
    case .openDyslexic: return .body
    }
  }
}

/// Text alignment choices exposed by the reader. The publisher default preserves the publication's
/// own alignment; the DesignSystem mirrors the domain type without importing ReaderCore.
public enum ReaderTextAlignment: String, CaseIterable, Identifiable, Sendable, Equatable {
  case publisherDefault
  case left
  case justify

  public var id: Self { self }
}

/// One theme choice in the appearance controls. A checkmark and the selected trait accompany the
/// color swatch so the current theme is never communicated by color alone.
public struct ReaderThemeOption: Sendable, Equatable, Identifiable {
  public let theme: ReaderTheme
  public let title: String
  public let accessibilityLabel: String

  public var id: ReaderTheme { theme }

  public init(theme: ReaderTheme, title: String, accessibilityLabel: String) {
    self.theme = theme
    self.title = title
    self.accessibilityLabel = accessibilityLabel
  }
}

/// One font-family row in the appearance controls.
public struct ReaderFontFamilyOption: Sendable, Equatable, Identifiable {
  public let family: ReaderFontFamily
  public let title: String
  public let accessibilityLabel: String

  public var id: ReaderFontFamily { family }

  public init(family: ReaderFontFamily, title: String, accessibilityLabel: String) {
    self.family = family
    self.title = title
    self.accessibilityLabel = accessibilityLabel
  }
}

/// One caller-supplied alignment choice in the appearance controls.
public struct ReaderTextAlignmentOption: Sendable, Equatable, Identifiable {
  public let alignment: ReaderTextAlignment
  public let title: String
  public let accessibilityLabel: String

  public var id: ReaderTextAlignment { alignment }

  public init(alignment: ReaderTextAlignment, title: String, accessibilityLabel: String) {
    self.alignment = alignment
    self.title = title
    self.accessibilityLabel = accessibilityLabel
  }
}

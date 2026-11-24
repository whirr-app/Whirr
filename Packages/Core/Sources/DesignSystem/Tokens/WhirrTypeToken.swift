import SwiftUI

/// Semantic type tokens. Stable by name (`rawValue`) so components and tests reference a
/// role rather than a raw `Font` value.
public enum WhirrTypeToken: String, CaseIterable, Sendable {
  case display
  case title
  case headline
  case body
  case subheadline
  case caption
  case caption2

  public var relativeTextStyle: Font.TextStyle {
    switch self {
    // Section-header scale: the display face adds the character; the size stays at the
    // pre-refresh header metric so Home's vertical rhythm is unchanged.
    case .display: .title2
    case .title: .title2
    case .headline: .headline
    case .body: .body
    case .subheadline: .subheadline
    case .caption: .caption
    case .caption2: .caption2
    }
  }

  public var font: Font {
    font(familyAvailable: WhirrDisplayFont.isFamilyAvailable)
  }

  public func font(familyAvailable: Bool) -> Font {
    switch self {
    case .display:
      return WhirrDisplayFont.resolve(
        textStyle: relativeTextStyle, face: .bold, familyAvailable: familyAvailable)
    case .title:
      return WhirrDisplayFont.resolve(
        textStyle: relativeTextStyle, face: .medium, familyAvailable: familyAvailable)
    case .headline: return .headline
    case .body: return .body
    case .subheadline: return .subheadline
    case .caption: return .caption
    case .caption2: return .caption2
    }
  }
}

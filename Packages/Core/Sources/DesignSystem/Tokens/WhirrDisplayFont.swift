import Foundation
import SwiftUI

#if canImport(UIKit)
  import CoreText
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Resolves the optional display face and falls back when the app's font registration is absent.
public enum WhirrDisplayFont {
  public enum Face: Equatable, Sendable {
    case medium
    case bold

    /// The explicit value requested on Space Grotesk's `wght` axis.
    public var weightAxisValue: Double {
      switch self {
      case .medium: 500
      case .bold: 700
      }
    }

    var fallbackWeight: Font.Weight {
      switch self {
      case .medium: .semibold
      case .bold: .bold
      }
    }
  }

  /// The variable font's PostScript name. Both display faces are instances of this one file.
  ///
  /// `SpaceGrotesk-Variable.ttf` ships one `wght` axis spanning 300-700 with a default of 300, so
  /// the registered name says `Light` though neither face uses it; both pin the axis. With no
  /// static instances, a face that cannot pin the axis falls back. The upstream licence ships
  /// beside the font as `OFL.txt`.
  public static let fontName = "SpaceGrotesk-Light"
  public static let wghtAxisIdentifier: UInt32 = 0x7767_6874

  /// Cached once because every semantic font lookup reaches the default token path.
  public static let isFamilyAvailable: Bool = {
    #if canImport(UIKit)
      return UIFont(name: fontName, size: 1) != nil
    #elseif canImport(AppKit)
      return NSFont(name: fontName, size: 1) != nil
    #else
      return false
    #endif
  }()

  public static func resolve(
    textStyle: Font.TextStyle,
    face: Face = .medium,
    familyAvailable: Bool
  ) -> Font {
    guard familyAvailable else {
      return .system(textStyle).weight(face.fallbackWeight)
    }

    #if canImport(UIKit)
      guard let uiFont = scaledUIFont(face: face, textStyle: textStyle) else {
        return .system(textStyle).weight(face.fallbackWeight)
      }
      return Font(uiFont)
    #else
      // The package's macOS test process cannot construct the UIKit font used by the app.
      return .system(textStyle).weight(face.fallbackWeight)
    #endif
  }

  #if canImport(UIKit)
    /// Returns the registered variable font with its `wght` axis pinned before Dynamic Type
    /// scaling. App-side UIKit consumers use this same construction as SwiftUI tokens.
    public static func scaledUIFont(
      face: Face,
      textStyle: Font.TextStyle,
      uiTextStyle: UIFont.TextStyle? = nil
    ) -> UIFont? {
      let baseSize = basePointSize(for: textStyle)
      guard let baseFont = UIFont(name: fontName, size: baseSize) else {
        return nil
      }

      let variation: [NSNumber: NSNumber] = [
        NSNumber(value: wghtAxisIdentifier): NSNumber(value: face.weightAxisValue)
      ]
      let variationAttribute = UIFontDescriptor.AttributeName(
        rawValue: kCTFontVariationAttribute as String
      )
      let descriptor = baseFont.fontDescriptor.addingAttributes([
        variationAttribute: variation
      ])
      let axisPinnedFont = UIFont(descriptor: descriptor, size: baseSize)
      let metricsTextStyle = uiTextStyle ?? metricsTextStyle(for: textStyle)
      return UIFontMetrics(forTextStyle: metricsTextStyle).scaledFont(for: axisPinnedFont)
    }

    private static func metricsTextStyle(for textStyle: Font.TextStyle) -> UIFont.TextStyle {
      if textStyle == .largeTitle { return .largeTitle }
      if textStyle == .title { return .title1 }
      if textStyle == .title2 { return .title2 }
      if textStyle == .title3 { return .title3 }
      if textStyle == .headline { return .headline }
      if textStyle == .subheadline { return .subheadline }
      if textStyle == .callout { return .callout }
      if textStyle == .footnote { return .footnote }
      if textStyle == .caption { return .caption1 }
      if textStyle == .caption2 { return .caption2 }
      return .body
    }
  #endif

  public static func basePointSize(for textStyle: Font.TextStyle) -> CGFloat {
    if textStyle == .largeTitle { return 34 }
    if textStyle == .title { return 28 }
    if textStyle == .title2 { return 22 }
    if textStyle == .title3 { return 20 }
    if textStyle == .headline { return 17 }
    if textStyle == .subheadline { return 15 }
    if textStyle == .body { return 17 }
    if textStyle == .callout { return 16 }
    if textStyle == .footnote { return 13 }
    if textStyle == .caption { return 12 }
    if textStyle == .caption2 { return 11 }
    return 17
  }
}

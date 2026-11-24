import DesignSystem
import SwiftUI
import Testing
import UIKit

@testable import Whirr

/// Which colour a transcript opened from a list wears: the show's, where the list knows it.
@MainActor
@Suite("Transcript accent")
struct TranscriptAccentTests {

  /// A pale cover once kept the app's ink, near-white in light appearance, which left Mark as ad
  /// at about 1.1:1. Each appearance now pairs its own ink with its own fill.
  @Test(
    "a show's colour pairs with an ink that reads on it in both appearances",
    arguments: [
      ("pale yellow", WhirrRGBColor(1, 0.95, 0.6)),
      ("mid grey", WhirrRGBColor(0.5, 0.5, 0.5)),
      ("navy", WhirrRGBColor(0.05, 0.1, 0.3)),
    ])
  func showColourIsLegible(name: String, cover: WhirrRGBColor) {
    let accent = TranscriptAccent.show(cover.color)
    for style in [UIUserInterfaceStyle.light, .dark] {
      let fill = Self.rgb(accent.fill, style)
      let ink = Self.rgb(accent.ink, style)
      #expect(contrastRatio(fill, ink) >= 4.5, "\(name) in \(style == .dark ? "dark" : "light")")
    }
  }

  @Test("a cover too grey for a colour falls back to the app's tint")
  func greyCover() {
    let accent = TranscriptAccent.show(nil)
    #expect(accent.fill == AppChrome.tint)
    #expect(accent.ink == AppChrome.onTint)
  }

  @Test("the show page's colour reaches the sheet the shell raises")
  func openerCarriesShowColour() {
    var opened: (String, String, Color?)?
    let opener = EpisodeTranscriptOpener { itemID, episodeID, accent in
      opened = (itemID, episodeID, accent)
    }
    opener.open("item", "episode", .orange)
    #expect(opened?.0 == "item")
    #expect(opened?.1 == "episode")
    #expect(opened?.2 == .orange)
  }

  private static func rgb(_ color: Color, _ style: UIUserInterfaceStyle) -> WhirrRGBColor {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
      .getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    return WhirrRGBColor(Double(red), Double(green), Double(blue))
  }
}

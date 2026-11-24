import SwiftUI
import Testing

@testable import DesignSystem

/// The cover accent has three jobs and one value, and each needs its own contrast check.
///
/// `CoverWashTests` guards the bands `CoverWash` places for weight and hue uniformity; contrast is
/// separate. As an eyebrow on the card wash the accent is text and owes 4.5:1. As a progress bar
/// or status glyph on the page wash it is a graphic and owes 3:1. As the selected filter chip's
/// fill under a fixed ink it owes 4.5:1 the other way round.
///
/// These sweep the hue circle because failures are hue-dependent: the dark bands clear all three
/// floors and the light band fails all three across the warm arc.
@Suite("Cover accent contrast")
struct CoverAccentFillContrastTests {

  /// 5° steps around the circle. `CoverWash.from` clamps saturation and brightness into its own
  /// bands, so what varies here is hue.
  private static let hues: [Double] = stride(from: 0.0, to: 1.0, by: 5.0 / 360.0).map { $0 }

  private static func wash(_ hue: Double) -> CoverWash {
    CoverWash.from(hue: hue, saturation: 0.8, brightness: 0.8)
  }

  /// The worst ratio around the circle, and the hue it happens at.
  private static func worst(
    _ ratio: (CoverWash) -> Double
  ) -> (ratio: Double, hue: Double) {
    hues.reduce(into: (ratio: Double.greatestFiniteMagnitude, hue: 0.0)) { low, hue in
      let value = ratio(wash(hue))
      if value < low.ratio { low = (value, hue * 360) }
    }
  }

  // MARK: - The accent as a fill, under a fixed ink

  @Test("a chip's own ink clears AA on the accent it is laid over")
  func selectedChipTextClearsAA() {
    var failures: [String] = []
    for hue in Self.hues {
      let wash = Self.wash(hue)
      for (name, fill) in [("light", wash.lightAccent!), ("dark", wash.darkAccent!)] {
        let pair = legibleAccentPair(for: fill.rgbColor)
        let ratio = contrastRatio(pair.ink, pair.fill)
        if ratio < 4.5 {
          failures.append(String(format: "%@ hue %.0f: %.2f:1", name, hue * 360, ratio))
        }
      }
    }
    #expect(failures.isEmpty, "selected chip fails AA at: \(failures.joined(separator: ", "))")
  }

  // MARK: - The accent as a mark, on the wash behind it

  @Test("the eyebrow clears the text floor on the card wash")
  func accentOnCardClearsTextFloor() {
    var failures: [String] = []
    for hue in Self.hues {
      let wash = Self.wash(hue)
      for (name, mark, ground) in [
        ("light", wash.lightAccent!, wash.light), ("dark", wash.darkAccent!, wash.dark),
      ] {
        let solved = nonTextContrastColor(
          preferred: mark.rgbColor, on: ground.rgbColor, minimumRatio: 4.5)
        let ratio = contrastRatio(solved, ground.rgbColor)
        if ratio < 4.5 {
          failures.append(String(format: "%@ hue %.0f: %.2f:1", name, hue * 360, ratio))
        }
      }
    }
    #expect(failures.isEmpty, "eyebrow fails AA at: \(failures.joined(separator: ", "))")
  }

  @Test("the row's marks clear the non-text floor on the page wash")
  func accentOnPageClearsNonTextFloor() {
    var failures: [String] = []
    for hue in Self.hues {
      let wash = Self.wash(hue)
      for (name, mark, ground) in [
        ("light", wash.lightAccent!, wash.lightPage), ("dark", wash.darkAccent!, wash.darkPage),
      ] {
        let solved = nonTextContrastColor(
          preferred: mark.rgbColor, on: ground.rgbColor, minimumRatio: 3)
        let ratio = contrastRatio(solved, ground.rgbColor)
        if ratio < 3 {
          failures.append(String(format: "%@ hue %.0f: %.2f:1", name, hue * 360, ratio))
        }
      }
    }
    #expect(failures.isEmpty, "row marks fail 1.4.11 at: \(failures.joined(separator: ", "))")
  }

  /// The unsolved band fails contrast. Pinned so the solve cannot be quietly deleted.
  @Test("the unsolved band is the thing being replaced")
  func theUnsolvedBandFails() {
    let card = Self.worst { contrastRatio($0.lightAccent!.rgbColor, $0.light.rgbColor) }
    let page = Self.worst { contrastRatio($0.lightAccent!.rgbColor, $0.lightPage.rgbColor) }
    #expect(card.ratio < 4.5, "the light band now carries text unaided; this guard is obsolete")
    #expect(page.ratio < 3, "the light band now clears 1.4.11 unaided; this guard is obsolete")

    // The dark bands are built in OKLab against these same grounds and already clear both.
    let darkCard = Self.worst { contrastRatio($0.darkAccent!.rgbColor, $0.dark.rgbColor) }
    let darkPage = Self.worst { contrastRatio($0.darkAccent!.rgbColor, $0.darkPage.rgbColor) }
    #expect(darkCard.ratio >= 4.5, "the dark band regressed on the card: \(darkCard)")
    #expect(darkPage.ratio >= 3, "the dark band regressed on the page: \(darkPage)")
  }

  /// A solved mark still has to look like the cover's colour. The solve moves toward black or
  /// white, which desaturates, so this bounds how far a legibility fix is allowed to wash the hue
  /// out before it stops being the show's accent at all.
  @Test("solving for contrast keeps the accent's hue")
  func solvedMarksKeepTheirHue() {
    for hue in Self.hues {
      let wash = Self.wash(hue)
      let solved = nonTextContrastColor(
        preferred: wash.lightAccent!.rgbColor, on: wash.light.rgbColor, minimumRatio: 4.5)
      let before = wash.lightAccent!.oklabHueDegrees
      let solvedHue = OKLab(red: solved.red, green: solved.green, blue: solved.blue)
      let drift = abs((solvedHue.hueRadians * 180 / .pi) - before)
      let comment = String(format: "hue %.0f drifted %.1f degrees when solved", hue * 360, drift)
      #expect(min(drift, 360 - drift) < 6, Comment(rawValue: comment))
    }
  }
}

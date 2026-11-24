import DesignSystem
import SwiftUI
import UIKit

// A drained dark page (`CoverAmbientPalette.page(from:mode:increasedContrast:)`) goes almost to
// black, and the cover's colour moves to its marks: the primary action and the progress fill. These
// are the pieces that carry it there.

extension CoverAmbientPalette {
  /// The standard dark page's primary action fill for this evidence, or `nil` for the ink.
  ///
  /// The cover's colour wherever it has a hue by the card's test, at the hue of its saturated form,
  /// so it is also the mark its drained card carries. A page with no hue keeps its action ink.
  static func darkActionFill(from evidence: CoverPageEvidence) -> WhirrRGBColor? {
    guard let cluster = evidence.cluster else { return nil }
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    var brightness: CGFloat = 0
    var alpha: CGFloat = 0
    UIColor(red: cluster.red, green: cluster.green, blue: cluster.blue, alpha: 1)
      .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
    guard Double(saturation) >= minimumPageHueSaturation else { return nil }
    return CoverWash.drainedMark(for: cluster).rgbColor
  }
}

extension AmbientCanvas {
  /// The cover colour this page's primary action carries, or `nil` while it carries the ink.
  var coverMark: Color? {
    primaryAction.fill == inkRGB ? nil : primaryAction.fill.color
  }
}

private struct AmbientProgressFillKey: EnvironmentKey {
  static let defaultValue: Color? = nil
}

extension EnvironmentValues {
  /// The colour an ambient page's progress fill draws in, or `nil` for the fill's own.
  var ambientProgressFill: Color? {
    get { self[AmbientProgressFillKey.self] }
    set { self[AmbientProgressFillKey.self] = newValue }
  }
}

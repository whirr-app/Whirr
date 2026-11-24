import Foundation

/// The copper turn: how a dark surface bends warm yellows towards red before asking sRGB for
/// colour.
///
/// Towards black, sRGB holds little chroma from orange through mustard, so the gamut cap flattened
/// that band into one brown-gold shared by every warm cover. Turned towards red, where the dark
/// gamut holds more, they stay distinct. Chosen on device over darkening the band and over a
/// milder mix of both.
///
/// Dark surfaces take it: the full-screen page, the dark card, the dark page wash. Marks do not
/// (the warm arc holds real colour at an accent's lightness), nor does a light surface.
public enum DarkWarmBand {
  /// OKLCh hue, in degrees, at the centre of the band: mustard.
  public static let peakHueDegrees = 82.0
  /// Degrees either side of the peak at which the band has faded to nothing: red on one side,
  /// lemon on the other.
  public static let halfWidthDegrees = 35.0
  /// How far a hue at the band's peak turns, towards amber and copper.
  public static let turnDegrees = 28.0

  /// The share of `turnDegrees` a hue takes: all of it at the peak, falling linearly to none at
  /// `halfWidthDegrees` either side.
  public static func share(hueRadians: Double) -> Double {
    var distance = abs(hueRadians * 180 / .pi - peakHueDegrees)
      .truncatingRemainder(dividingBy: 360)
    if distance > 180 { distance = 360 - distance }
    return max(0, 1 - distance / halfWidthDegrees)
  }

  /// The hue a dark surface paints for this cover hue, in radians.
  public static func turned(hueRadians: Double) -> Double {
    hueRadians - turnDegrees * share(hueRadians: hueRadians) * .pi / 180
  }
}

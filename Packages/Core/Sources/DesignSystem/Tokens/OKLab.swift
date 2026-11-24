import Foundation

/// A colour in OKLab, a perceptually uniform space where equal numeric steps are equal visible
/// steps regardless of hue.
///
/// The cover wash needs this because HSB lacks that property: at one saturation an orange carries
/// far more visible colour than a blue, so no single dark clamp band serves both (the value that
/// keeps blues from looking flat pushes warms into brown).
///
/// Chroma is held fixed where the design allows (the dark accent is one pair for the whole
/// circle). The dark fill cannot, since sRGB has far less room for a dark cyan than a dark red, so
/// it names a target and takes what each hue can hold; see `displayableChroma`.
///
/// Conversion matrices are Björn Ottosson's published sRGB fits.
///
/// Public because the ambient page policy in the App target needs this arithmetic to clamp a
/// cover's lightness while holding its chroma and hue. Only the colour space is exposed: the
/// bands, pole boundary and cluster floor stay with their pages.
public struct OKLab: Equatable, Sendable {
  public let lightness: Double
  public let a: Double
  public let b: Double

  public var chroma: Double { (a * a + b * b).squareRoot() }
  public var hueRadians: Double { atan2(b, a) }

  public init(lightness: Double, a: Double, b: Double) {
    self.lightness = lightness
    self.a = a
    self.b = b
  }

  public init(red: Double, green: Double, blue: Double) {
    let r = Self.linear(red)
    let g = Self.linear(green)
    let bl = Self.linear(blue)

    let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl)
    let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl)
    let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl)

    lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
    self.a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    self.b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
  }

  /// The colour in sRGB, clamped into gamut. At the wash's tiny chroma nothing clips, but the
  /// clamp keeps the type honest for any caller that asks for a vivid one.
  public var rgb: (Double, Double, Double) {
    let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
    let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
    let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)

    return (
      Self.gammaEncoded(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
      Self.gammaEncoded(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
      Self.gammaEncoded(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    )
  }

  /// The largest chroma this lightness and hue can hold in sRGB, times a small safety margin.
  ///
  /// The gamut is very asymmetric at low lightness: at 0.20, red reaches 0.090 and magenta 0.116,
  /// but teal stops at 0.039 (sRGB cannot make a dark saturated cyan), so the wash asks for a
  /// target and calls this to find what each hue can have.
  ///
  /// Bisection, not an analytic edge solve: twenty halvings land inside a thousandth, and this
  /// runs once per cover.
  public static func displayableChroma(
    lightness: Double, hueRadians: Double, upTo target: Double
  ) -> Double {
    guard !Self(lightness: lightness, a: 0, b: 0).clips else { return 0 }
    guard Self(lightness: lightness, chroma: target, hueRadians: hueRadians).clips else {
      return target
    }

    var reachable = 0.0
    var tooFar = target
    for _ in 0..<20 {
      let midpoint = (reachable + tooFar) / 2
      if Self(lightness: lightness, chroma: midpoint, hueRadians: hueRadians).clips {
        tooFar = midpoint
      } else {
        reachable = midpoint
      }
    }
    // Back off the very edge: the boundary colour is representable but rounds to a channel sitting
    // exactly at 0 or 255, and a card that has quietly landed on a clipped value is hard to spot.
    return reachable * 0.98
  }

  public init(lightness: Double, chroma: Double, hueRadians: Double) {
    self.init(lightness: lightness, a: chroma * cos(hueRadians), b: chroma * sin(hueRadians))
  }

  /// Whether converting to sRGB would need the gamut clamp in `rgb`, so the result would not hold
  /// the lightness and chroma asked for.
  private var clips: Bool {
    let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
    let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
    let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)

    return [
      4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
      -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
      -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    ].contains { $0 < 0 || $0 > 1 }
  }

  private static func linear(_ channel: Double) -> Double {
    channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
  }

  private static func gammaEncoded(_ channel: Double) -> Double {
    let encoded = channel <= 0.0031308 ? channel * 12.92 : 1.055 * pow(channel, 1 / 2.4) - 0.055
    return min(1, max(0, encoded))
  }
}

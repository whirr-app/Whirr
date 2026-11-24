import Foundation

/// One cluster from a cover's k-means pass: its centroid colour and the share of the analysed
/// artwork it covers.
public struct CoverAccentCandidate: Equatable, Sendable {
  public let red: Double
  public let green: Double
  public let blue: Double
  /// Share of the analysed cover this cluster covers, 0...1.
  public let weight: Double

  public init(red: Double, green: Double, blue: Double, weight: Double) {
    self.red = red
    self.green = green
    self.blue = blue
    self.weight = weight
  }
}

/// Chooses the cluster that reads as a cover's colour.
public enum CoverAccentSelection {
  /// The least perceptual colourfulness worth carrying into the cover wash.
  public static let minimumChroma = 0.02
  /// Colour relative to lightness under which a cluster reads as neutral. A beige background
  /// (0.033) falls under it; a muted grey-green photograph (0.050) and a dark green (0.11) clear
  /// it. Any higher and a muted cover is left with only its smallest, loudest detail.
  public static let minimumRelativeChroma = 0.045
  /// The least share of the cover a cluster must cover to speak for it. A sponsor's logo on a third
  /// of a percent of the cover is not its colour, however vivid, even when nothing else qualifies.
  public static let minimumWeight = 0.01
  /// Relative colour is measured as if at least this light, so a near-black cluster's faint tint
  /// is not magnified into a strong colour.
  public static let relativeLightnessFloor = 0.25
  /// Area weighting: a broad field outweighs a small vivid detail without area erasing colour.
  public static let weightExponent = 0.75
  /// Lightness below which a cluster starts to fade out of contention, and where it is gone.
  public static let darkFade: ClosedRange<Double> = 0.15...0.35
  /// Lightness above which a cluster starts to fade out of contention, and where it is gone.
  public static let lightFade: ClosedRange<Double> = 0.85...0.95

  /// OKLab chroma over lightness: how coloured a cluster reads for how light it is.
  public static func relativeChroma(_ oklab: OKLab) -> Double {
    oklab.chroma / max(oklab.lightness, relativeLightnessFloor)
  }

  /// Scores relative colourfulness and covered area, fading only the very dark and very light.
  ///
  /// Relative, not absolute, chroma: k-means reads true colours, so a near-neutral field carries
  /// as much absolute chroma as a real dark colour and won on area (a beige background over a
  /// green jumper). Relative chroma already discounts light colours, so there is no mid-lightness
  /// peak on top; with one, a pale sky across half a cover lost to red lettering on a twelfth.
  /// The area term uses the centroid's alpha, so a 1.6% retailer badge cannot beat a broad field
  /// by being more saturated.
  public static func score(_ candidate: CoverAccentCandidate) -> Double {
    let oklab = OKLab(red: candidate.red, green: candidate.green, blue: candidate.blue)
    let relative = relativeChroma(oklab)
    guard candidate.weight >= minimumWeight, oklab.chroma >= minimumChroma,
      relative >= minimumRelativeChroma
    else { return 0 }
    let area = pow(max(candidate.weight, 0), weightExponent)
    return relative * lightnessFade(oklab.lightness) * area
  }

  /// Full weight between `darkFade` and `lightFade`, falling linearly to none across each.
  static func lightnessFade(_ lightness: Double) -> Double {
    if lightness < darkFade.upperBound {
      return max(0, (lightness - darkFade.lowerBound) / (darkFade.upperBound - darkFade.lowerBound))
    }
    if lightness > lightFade.lowerBound {
      return max(0, (lightFade.upperBound - lightness) / (lightFade.upperBound - lightFade.lowerBound))
    }
    return 1
  }

  /// Returns the strongest coloured cluster, using input order to resolve complete ties.
  public static func select(from candidates: [CoverAccentCandidate]) -> CoverAccentCandidate? {
    var winner: CoverAccentCandidate?
    var winningScore = 0.0

    for candidate in candidates {
      let candidateScore = score(candidate)
      if candidateScore > winningScore
        || (candidateScore == winningScore && candidateScore > 0
          && candidate.weight > (winner?.weight ?? 0))
      {
        winner = candidate
        winningScore = candidateScore
      }
    }

    return winner
  }
}

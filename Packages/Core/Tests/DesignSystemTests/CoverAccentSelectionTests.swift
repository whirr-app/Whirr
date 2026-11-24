import Testing

@testable import DesignSystem

@Suite("Cover accent selection")
struct CoverAccentSelectionTests {
  private typealias Candidate = CoverAccentCandidate

  /// Real true-colour k-means output, centroid colour and cluster share both, read the way
  /// `CoverPaletteExtractor` reads covers. The Rest Is Science's beige background clears the
  /// absolute chroma floor and covers the most area; its colour is the dark green jumper.
  private static let restIsScience = [
    Candidate(red: 0.33, green: 0.30, blue: 0.26, weight: 0.077),
    Candidate(red: 0.91, green: 0.91, blue: 0.87, weight: 0.263),
    Candidate(red: 0.73, green: 0.69, blue: 0.63, weight: 0.385),
    Candidate(red: 0.11, green: 0.20, blue: 0.16, weight: 0.176),
    Candidate(red: 0.57, green: 0.50, blue: 0.43, weight: 0.098),
  ]
  /// Pale sky across half the cover, grass, and red and pink lettering on a twelfth of it.
  private static let rhymingRabbit = [
    Candidate(red: 0.49, green: 0.54, blue: 0.17, weight: 0.055),
    Candidate(red: 0.78, green: 0.40, blue: 0.45, weight: 0.085),
    Candidate(red: 0.50, green: 0.77, blue: 0.91, weight: 0.489),
    Candidate(red: 0.63, green: 0.76, blue: 0.39, weight: 0.233),
    Candidate(red: 0.35, green: 0.51, blue: 0.63, weight: 0.126),
  ]
  /// The Faith of Beasts' retail cover at 1200 pixels, standing in for the detail screen's JPEG.
  private static let faithOfBeastsHighFidelity = [
    Candidate(red: 0.331, green: 0.251, blue: 0.148, weight: 0.2019),
    Candidate(red: 0.794, green: 0.840, blue: 0.764, weight: 0.1309),
    Candidate(red: 0.606, green: 0.521, blue: 0.267, weight: 0.1284),
    Candidate(red: 0.225, green: 0.368, blue: 0.306, weight: 0.1943),
    Candidate(red: 0.366, green: 0.590, blue: 0.565, weight: 0.1272),
    Candidate(red: 0.115, green: 0.218, blue: 0.195, weight: 0.2173),
  ]
  /// The same cover at 240 pixels, standing in for the Home card's.
  private static let faithOfBeastsHomeCard = [
    Candidate(red: 0.373, green: 0.278, blue: 0.166, weight: 0.1885),
    Candidate(red: 0.826, green: 0.868, blue: 0.807, weight: 0.1289),
    Candidate(red: 0.625, green: 0.563, blue: 0.305, weight: 0.1326),
    Candidate(red: 0.167, green: 0.340, blue: 0.290, weight: 0.1809),
    Candidate(red: 0.340, green: 0.585, blue: 0.564, weight: 0.1206),
    Candidate(red: 0.138, green: 0.208, blue: 0.171, weight: 0.2485),
  ]

  /// The Rest Is Classified: a muted grey-green photograph, a white footer, and a sponsor's blue
  /// logo on a third of a percent of it, the only cluster vivid enough to pass the neutral floor.
  private static let restIsClassified = [
    Candidate(red: 0.400, green: 0.457, blue: 0.397, weight: 0.1829),
    Candidate(red: 0.937, green: 0.930, blue: 0.906, weight: 0.2078),
    Candidate(red: 0.623, green: 0.711, blue: 0.633, weight: 0.3594),
    Candidate(red: 0.172, green: 0.226, blue: 0.213, weight: 0.1753),
    Candidate(red: 0.421, green: 0.584, blue: 0.853, weight: 0.0034),
    Candidate(red: 0.075, green: 0.117, blue: 0.107, weight: 0.0713),
  ]

  @Test("selects the measured winner from each cover")
  func selectsMeasuredWinners() {
    #expect(CoverAccentSelection.select(from: Self.restIsScience) == Self.restIsScience[3])
    #expect(CoverAccentSelection.select(from: Self.rhymingRabbit) == Self.rhymingRabbit[2])
    #expect(CoverAccentSelection.select(from: Self.restIsClassified) == Self.restIsClassified[2])
  }

  @Test("never lets a speck of the cover speak for it")
  func speckDoesNotWinAlone() {
    let logo = Candidate(red: 0.421, green: 0.584, blue: 0.853, weight: 0.0034)
    let white = Candidate(red: 0.94, green: 0.94, blue: 0.94, weight: 0.9966)

    #expect(CoverAccentSelection.select(from: [logo, white]) == nil)
  }

  @Test("treats a near-neutral field as neutral however much of the cover it covers")
  func nearNeutralFieldDoesNotCompete() {
    #expect(CoverAccentSelection.score(Self.restIsScience[2]) == 0)
  }

  @Test("measures a near-black cluster's tint as if lighter, so it does not compete")
  func nearBlackDoesNotCompete() {
    #expect(
      CoverAccentSelection.score(Candidate(red: 0.05, green: 0.06, blue: 0.08, weight: 0.8)) == 0)
  }

  /// Two artwork variants of one cover must resolve to one colour, so the item-detail screen and
  /// the Home card agree. The selection has to hold this, not the fixtures.
  @Test("keeps the two Faith of Beasts variants on the same perceptual hue")
  func faithVariantsAgreeOnHue() throws {
    let highFidelity = try #require(CoverAccentSelection.select(from: Self.faithOfBeastsHighFidelity))
    let homeCard = try #require(CoverAccentSelection.select(from: Self.faithOfBeastsHomeCard))
    let hueDifference =
      abs(
        OKLab(red: highFidelity.red, green: highFidelity.green, blue: highFidelity.blue).hueRadians
          - OKLab(red: homeCard.red, green: homeCard.green, blue: homeCard.blue).hueRadians) * 180
      / .pi

    #expect(hueDifference < 5)
  }

  @Test("lets a large moderate field beat a tiny vivid speck")
  func areaDampsTinySpeck() {
    let speck = Candidate(red: 1, green: 0, blue: 0, weight: 0.01)
    let field = Candidate(red: 0.32, green: 0.58, blue: 0.55, weight: 0.75)

    #expect(CoverAccentSelection.select(from: [speck, field]) == field)
  }

  @Test("returns nil when every cluster is grey")
  func allGreyReturnsNil() {
    let candidates = [
      Candidate(red: 0.3, green: 0.3, blue: 0.3, weight: 0.5),
      Candidate(red: 0.7, green: 0.7, blue: 0.7, weight: 0.5),
    ]

    #expect(CoverAccentSelection.select(from: candidates) == nil)
  }

  @Test("never selects a zero-weight candidate")
  func zeroWeightDoesNotWin() {
    let zeroWeight = Candidate(red: 1, green: 0, blue: 0, weight: 0)
    let field = Candidate(red: 0.32, green: 0.58, blue: 0.55, weight: 0.75)

    #expect(CoverAccentSelection.select(from: [zeroWeight, field]) == field)
  }

  @Test("scores pure black and white as zero")
  func endpointsScoreZero() {
    #expect(CoverAccentSelection.score(Candidate(red: 0, green: 0, blue: 0, weight: 1)) == 0)
    #expect(CoverAccentSelection.score(Candidate(red: 1, green: 1, blue: 1, weight: 1)) == 0)
  }
}

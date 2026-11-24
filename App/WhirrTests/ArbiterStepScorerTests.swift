import CryptoKit
import Foundation
import Testing

@testable import Whirr

/// Pins the bundled arbiter model. The expected probabilities were computed on macOS 27.0.1
/// (26A434) with `NLModel.predictedLabelHypotheses(for:maximumCount: 2)["ad"]` over the same
/// `.mlmodel`, as ad-harness `train2.swift` scores steps. The sentences are invented.
@Suite("Arbiter step scorer")
struct ArbiterStepScorerTests {

  private static let expected: [(String, Double)] = [
    ("_", 0.072079606581102268),
    (
      "this episode is brought to you by our sponsor use code listen for twenty percent off your "
        + "first order", 0.088353328694441957
    ),
    (
      "so we went back to the archive and found the letters she had written to her brother that "
        + "winter", 0.0030176827555381466
    ),
    ("visit example dot com slash offer today terms apply", 0.96968293012803397),
    ("and that is where the story really begins", 0.017362031314403999),
  ]

  @Test("the source model is the frozen arbiter")
  func sourceModelIsFrozen() throws {
    let model = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Whirr/AdSkip/ArbiterClassifier.mlmodel")
    let digest = SHA256.hash(data: try Data(contentsOf: model))
      .map { String(format: "%02x", $0) }
      .joined()

    #expect(digest == "da6e608bf5a976cba3431c98fa18ce292b23688a07ec58fba6724a5ca093ecc1")
  }

  @Test("the bundled model scores steps as the harness did")
  func bundledProbabilitiesMatchTheHarness() async throws {
    let scorer = try ArbiterStepScorer.bundled()

    let probabilities = try await scorer.adProbabilities(forStepTexts: Self.expected.map(\.0))

    #expect(probabilities.count == Self.expected.count)
    for (probability, (text, expected)) in zip(probabilities, Self.expected) {
      #expect(abs(probability - expected) <= 1e-6, "\(text)")
    }
  }

  @Test("no steps give no probabilities")
  func emptyInput() async throws {
    let probabilities = try await ArbiterStepScorer.bundled().adProbabilities(forStepTexts: [])

    #expect(probabilities.isEmpty)
  }
}

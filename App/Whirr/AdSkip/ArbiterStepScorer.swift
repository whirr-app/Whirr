import AdSkip
import Foundation
import NaturalLanguage

/// Scores arbiter steps with the bundled text classifier, matching ad-harness `train2.swift` `pAd`.
/// The model is frozen (a retrain is a new rules revision) and loads on first call, since most
/// launches never score a step.
actor ArbiterStepScorer: AdStepScoring {

  enum Failure: Error {
    case modelMissing
  }

  private let url: URL
  private var model: NLModel?

  init(compiledModelAt url: URL) {
    self.url = url
  }

  static func bundled() throws -> ArbiterStepScorer {
    guard let url = Bundle.main.url(forResource: "ArbiterClassifier", withExtension: "mlmodelc")
    else { throw Failure.modelMissing }
    return ArbiterStepScorer(compiledModelAt: url)
  }

  func adProbabilities(forStepTexts texts: [String]) async throws -> [Double] {
    guard texts.isEmpty == false else { return [] }
    let model = try loadedModel()
    return texts.map { model.predictedLabelHypotheses(for: $0, maximumCount: 2)["ad"] ?? 0 }
  }

  private func loadedModel() throws -> NLModel {
    if let model { return model }
    let loaded = try NLModel(contentsOf: url)
    model = loaded
    return loaded
  }
}

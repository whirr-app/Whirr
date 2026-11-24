import AdSkip
import Foundation
import Persistence

extension AdSkipCoordinator {
  /// Each printed ad's library keys as the store stands. The loaded library is dropped when this
  /// differs from what it was built with: an ad merged in place keeps its id and changes its keys.
  static func audioKeys(
    of creatives: [StoredAdSignatureCreative], groups: [EpisodeKey: Set<EpisodeKey>]
  ) -> [Int64: Set<EpisodeKey>] {
    Dictionary(
      creatives.filter(\.hasAudioPrint).map {
        ($0.id, AdSkipPlanBook.audioKeys(teachers: Set($0.teachers.map(EpisodeKey.init)), groups: groups))
      }, uniquingKeysWith: { first, _ in first })
  }

  /// The store's prints by ad, for the same-ad rule.
  func learnedPrints() async throws -> [Int64: AudioPrint] {
    var prints: [Int64: AudioPrint] = [:]
    for creative in try await dependencies.signatures.learnedAudioPrints() {
      prints[creative.id] = AudioPrint(littleEndianData: creative.audioPrint)
    }
    return prints
  }
}

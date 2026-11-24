import AdSkip
import Foundation
import Persistence

/// A cached `ConfirmedReach` result: the episode's print file and the creatives it was matched
/// against name its inputs, since neither a print file's name nor a creative's print is reused.
struct ConfirmedReachEntry: Sendable {
  let printFileName: String
  let creativeIds: [Int64]
  let matches: [ConfirmedReach.Match]
}

/// Confirmed reach: a creative a listener's mark taught is served wherever its audio
/// plays, as a mark is, and saved as a store range naming it. Only audio prints are read.
extension AdSkipCoordinator {

  /// Where the confirmed creatives play in the episode. Not matched: the creatives its own marks
  /// taught, which those marks already serve, and those the listener undid in it.
  func confirmedMatches(
    for row: AdSkipEpisodeRecord, rowId: Int64, audio: AudioLibrary
  ) async throws -> [ConfirmedReach.Match] {
    guard audio.confirmedPrints.isEmpty == false, let fileName = row.audioPrintFileName,
      let print = audio.audioPrint(of: row.identity)
    else { return [] }
    let own = Set(try await dependencies.episodes.listenerMarks(forEpisodeId: rowId).compactMap(\.creativeId))
    let suppressed = try await dependencies.episodes.confirmedSuppressions(forEpisodeId: rowId)
    let ids = audio.confirmedPrints.keys.filter { own.contains($0) == false && suppressed.contains($0) == false }
      .sorted()
    guard ids.isEmpty == false else { return [] }
    if let cached = plans.confirmedReachCache[row.identity], cached.printFileName == fileName,
      cached.creativeIds == ids
    {
      return cached.matches
    }
    let matches = ConfirmedReach.matches(
      in: print, creatives: ids.compactMap { id in audio.confirmedPrints[id].map { (id: id, print: $0) } })
    plans.confirmedReachCache[row.identity] = ConfirmedReachEntry(
      printFileName: fileName, creativeIds: ids, matches: matches)
    return matches
  }

  /// `ranges` with `matches` laid over them: each match is served whole as a store range naming
  /// its creative, and the ranges lose what it covers.
  static func laying(_ matches: [ConfirmedReach.Match], over ranges: [AdSkipRange]) -> [AdSkipRange] {
    guard matches.isEmpty == false else { return ranges }
    return ConfirmedReach.laying(matches, over: ranges.map { ($0.startTime, $0.endTime, $0.endsItem) }).map {
      piece in
      guard let source = piece.source else {
        return AdSkipRange(
          startTime: piece.start, endTime: piece.end, meanAdProbability: 1,
          rulesRevision: AdSkipRules.revision, fromStore: true, endsItem: false,
          creativeId: piece.creativeId)
      }
      var range = ranges[source]
      range.startTime = piece.start
      range.endTime = piece.end
      range.endsItem = piece.endsItem
      return range
    }
  }
}

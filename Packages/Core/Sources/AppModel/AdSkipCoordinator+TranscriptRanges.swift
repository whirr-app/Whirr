import AdSkip
import Foundation
import Persistence

/// The coordinator as the transcript view's ad source.
extension AdSkipCoordinator {

  /// The episode's ranges as the player will skip them, with where each came from, or none under
  /// the rules `skipRanges(for:)` applies. Unlike that call this does not move the episode up the
  /// analysis queue: reading a transcript is not a request to analyse. The pre-roll edge and the
  /// player's join are applied, so the view marks what plays. A joined range is the listener's when
  /// any part is, and a host read only when every part is.
  public func transcriptAdRanges(for identity: AdSkipEpisodeIdentity) async -> [TranscriptAdRange] {
    guard let local = currentLocalEpisodes[identity],
      let rows = await servedRows(of: identity, fileURL: local.fileURL)
    else { return [] }
    var joined: [TranscriptAdRange] = []
    for row in rows.sorted(by: { $0.startTime < $1.startTime }) {
      let start = PlaybackEdges.start(atItemStartFor: row.startTime)
      let origin: TranscriptAdRange.Origin =
        row.fromListener ? .listener : row.fromHostRead ? .hostRead : .detected
      if let last = joined.last, start - last.end <= PlaybackEdges.joinGapSeconds {
        joined[joined.count - 1] = TranscriptAdRange(
          start: last.start, end: max(last.end, row.endTime),
          origin: Self.joined(last.origin, origin))
      } else {
        joined.append(TranscriptAdRange(start: start, end: row.endTime, origin: origin))
      }
    }
    return joined
  }

  private static func joined(
    _ first: TranscriptAdRange.Origin, _ second: TranscriptAdRange.Origin
  ) -> TranscriptAdRange.Origin {
    if first == .listener || second == .listener { return .listener }
    return first == .hostRead && second == .hostRead ? .hostRead : .detected
  }

  /// Whether the transcript can offer a mark for the episode: nothing while ad skip is off, a
  /// reason while the episode is not analysed or its file is not the one analysed.
  public func markingAvailability(for identity: AdSkipEpisodeIdentity) async
    -> TranscriptAdMarking.Availability
  {
    guard isEnabled == true else { return .hidden }
    guard let local = currentLocalEpisodes[identity],
      let row = try? await dependencies.episodes.episode(for: identity),
      row.state == .analysed,
      dependencies.fingerprinting.fingerprint(ofFileAt: local.fileURL) == row.fingerprint
    else { return .unavailable(.notAnalysed) }
    return .available
  }

  /// Undoes a range the transcript view showed, at once: the stored rows it overlaps, other than
  /// the listener's own, are deleted and the ranges signalled, so the range goes even when no
  /// tombstone can be built. The worker then tombstones the span and recomputes, as for the
  /// player's Undo, from the rows deleted here, which the store no longer holds. A range the
  /// listener marked is removed instead (`removeListenerMarks`).
  public func undoRange(
    identity: AdSkipEpisodeIdentity, start: Double, end: Double, origin: TranscriptAdRange.Origin
  ) async {
    guard origin != .listener else {
      await removeListenerMarks(identity: identity, start: start, end: end)
      return
    }
    // A joined range can hold both kinds, so an undo takes every row the span overlaps.
    guard currentLocalEpisodes[identity] != nil,
      let row = try? await dependencies.episodes.episode(for: identity), let rowId = row.id,
      let removed = try? await dependencies.episodes.deleteRanges(
        episodeId: rowId, overlapping: start, end),
      removed.isEmpty == false
    else { return }
    rangeChanges.signal()
    pendingUndos.append(PendingUndo(identity: identity, start: start, end: end, removed: removed))
    await wake()
  }

  /// The episode's stored ranges that are served under the current rules: the setting is on, the
  /// episode is analysed, the file still matches its fingerprint and the rules revision is one
  /// still served. Nil when any of that fails.
  func servedRows(of identity: AdSkipEpisodeIdentity, fileURL: URL) async -> [AdSkipRange]? {
    guard isEnabled == true,
      let row = try? await dependencies.episodes.episode(for: identity),
      row.state == .analysed, let rowId = row.id,
      dependencies.fingerprinting.fingerprint(ofFileAt: fileURL) == row.fingerprint,
      let ranges = try? await dependencies.episodes.ranges(forEpisodeId: rowId)
    else { return nil }
    // A range saved under older rules waits for the recompute a rules change schedules, except
    // the revisions the changeover still serves (`AdSkipRules.servedRevisions`).
    return ranges.filter { AdSkipRules.servedRevisions.contains($0.rulesRevision) }
  }
}

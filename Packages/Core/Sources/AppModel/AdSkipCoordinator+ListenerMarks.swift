import AdSkip
import Foundation
import Persistence

/// A stretch the listener marked as an ad, queued for the worker.
struct PendingMark: Sendable, Equatable {
  let identity: AdSkipEpisodeIdentity
  let start: Double
  let end: Double
}

/// The listener's own ad marks (`ListenerMarks`): served whole beside what analysis found, and
/// taught to the signature store as a confirmed ad (a short mark abutting an ad served is taught
/// from the span joining the two: `ListenerMarks.teachingSpan`). Only times, hashes and an audio print are
/// kept; the transcript they are read from is not (SECURITY rule 20).
///
/// A mark is applied by the worker, never by the caller, so it is serialised with a recompute: the
/// recompute's final save replaces every range of an episode, and a mark written from outside
/// would be lost to it. A mark queued during a recompute is applied once that recompute has saved,
/// over the ranges it saved.
extension AdSkipCoordinator {

  /// Queues a mark on `start..<end` of the episode, applied by the worker without waiting for
  /// charging. Refused, silently, unless ad skip is on and the span is long enough
  /// (`ListenerMarks.isLongEnough`, tested against the ads the episode serves: a short span is
  /// kept only beside one); the worker also refuses it unless the episode is analysed, still the
  /// file that was analysed, and has a complete transcript of the listener's. The edges are the
  /// ones given: they are not moved to a pause.
  public func markAd(identity: AdSkipEpisodeIdentity, start: Double, end: Double) async {
    guard isEnabled == true, start.isFinite, end.isFinite, start >= 0, end > start,
      currentLocalEpisodes[identity] != nil,
      await isLongEnough(identity, start: start, end: end)
    else { return }
    pendingMarks.append(PendingMark(identity: identity, start: start, end: end))
    await wake()
  }

  /// `ListenerMarks.isLongEnough` against the ranges the episode serves, as the transcript shows
  /// them. They are read only for a span under the minimum, which is the only one they can change.
  private func isLongEnough(_ identity: AdSkipEpisodeIdentity, start: Double, end: Double) async -> Bool {
    let shown =
      end - start < ListenerMarks.minimumSeconds
      ? await transcriptAdRanges(for: identity).map { TimeSpan(start: $0.start, end: $0.end) } : []
    return ListenerMarks.isLongEnough(start: start, end: end, beside: shown)
  }

  /// Removes the marks `start..<end` overlaps, their served ranges and the creatives they taught,
  /// writing no tombstone: the listener took back their own word, they did not say the audio is
  /// not an ad. The ranges are signalled at once and a recompute restores what the marks had cut.
  func removeListenerMarks(identity: AdSkipEpisodeIdentity, start: Double, end: Double) async {
    guard currentLocalEpisodes[identity] != nil,
      let row = try? await dependencies.episodes.episode(for: identity), let rowId = row.id,
      let removed = try? await dependencies.episodes.removeListenerMarks(
        episodeId: rowId, overlapping: start, end),
      removed.isEmpty == false
    else { return }
    let creatives = Set(removed.compactMap(\.creativeId))
    if creatives.isEmpty == false {
      do {
        _ = try await dependencies.signatures.apply(AdSignatureStoreChange(deletions: creatives))
        plans.invalidateAudioPlans()
      } catch {
        Self.log.error("Ad-skip mark removal failed: \(String(describing: type(of: error)), privacy: .public)")
      }
    }
    listenerMarkRemovals += 1
    isRecomputePending = true
    isListenerRecomputeOwed = true
    rangeChanges.signal()
    await wake()
  }

  /// A recompute that was running when a mark was removed may have saved ranges that still hold
  /// it, so it runs once more.
  func recomputeAgainIfMarksRemoved(since removals: Int) async {
    guard listenerMarkRemovals != removals else { return }
    isRecomputePending = true
    isListenerRecomputeOwed = true
    await wake()
  }

  /// `ranges` with the episode's marks laid over them. Any range of the listener's own in `ranges`
  /// is dropped first: the marks are read from the table and served afresh.
  func layingListenerMarks(over ranges: [AdSkipRange], episodeId: Int64) async throws -> [AdSkipRange] {
    Self.laying(try await dependencies.episodes.listenerMarks(forEpisodeId: episodeId), over: ranges)
  }

  static func laying(_ marks: [AdSkipListenerMark], over ranges: [AdSkipRange]) -> [AdSkipRange] {
    let others = ranges.filter { $0.fromListener == false }
    let pieces = ListenerMarks.laying(
      marks.map { TimeSpan(start: $0.startTime, end: $0.endTime) },
      over: others.map { ($0.startTime, $0.endTime, $0.endsItem) })
    return pieces.map { piece in
      guard let source = piece.source else {
        return AdSkipRange(
          startTime: piece.start, endTime: piece.end, meanAdProbability: 1,
          rulesRevision: AdSkipRules.revision, fromStore: false, endsItem: false, fromListener: true)
      }
      var range = others[source]
      range.startTime = piece.start
      range.endTime = piece.end
      range.endsItem = piece.endsItem
      return range
    }
  }

  /// Applies the queued marks, each in one change to the signature store and one to the episode's
  /// ranges. A failure keeps the marks not yet applied and is not thrown, so it holds up nothing
  /// else.
  func applyPendingMarks() async {
    guard pendingMarks.isEmpty == false else { return }
    var pending = pendingMarks
    pendingMarks = []
    var changed = false
    while let mark = pending.first {
      do {
        if try await apply(mark) { changed = true }
        pending.removeFirst()
      } catch {
        pendingMarks = pending + pendingMarks
        // Only the error's type: never a name or content.
        Self.log.error("Ad-skip mark failed: \(String(describing: type(of: error)), privacy: .public)")
        break
      }
    }
    if changed { rangeChanges.signal() }
  }

  /// Whether the mark was applied. False, with nothing written, when it is refused.
  private func apply(_ mark: PendingMark) async throws -> Bool {
    guard let episode = try await markableEpisode(mark.identity) else { return false }
    // The caller's check may be stale: what it was beside can have been undone since.
    guard await isLongEnough(mark.identity, start: mark.start, end: mark.end) else { return false }
    let now = dependencies.now()
    let held = try await dependencies.episodes.listenerMarks(forEpisodeId: episode.rowId)
    let isNew = held.contains { $0.startTime == mark.start && $0.endTime == mark.end } == false
    let creativeId =
      isNew
      ? try await teach(
        mark.identity, rowId: episode.rowId, start: mark.start, end: mark.end,
        transcript: episode.transcript) : nil
    do {
      let stored = try await dependencies.episodes.addListenerMark(
        episodeId: episode.rowId, startTime: mark.start, endTime: mark.end, creativeId: creativeId,
        createdAt: now, ranges: { marks, ranges in Self.laying(marks, over: ranges) })
      guard stored else { throw MarkEpisodeGone() }
    } catch {
      // The creative would have no mark to remove it.
      if let creativeId {
        _ = try? await dependencies.signatures.apply(AdSignatureStoreChange(deletions: [creativeId]))
      }
      if error is MarkEpisodeGone { return false }
      throw error
    }
    if creativeId != nil { didTeach() }
    return true
  }

  /// The episode's row and the listener's complete transcript, when a mark may be applied to it:
  /// ad skip is on, and the episode is downloaded, analysed and still the file analysed.
  private func markableEpisode(
    _ identity: AdSkipEpisodeIdentity
  ) async throws -> (rowId: Int64, transcript: Transcript)? {
    guard isEnabled == true, let local = currentLocalEpisodes[identity],
      let reader = dependencies.listenerTranscripts,
      let row = try await dependencies.episodes.episode(for: identity), row.state == .analysed,
      let rowId = row.id,
      dependencies.fingerprinting.fingerprint(ofFileAt: local.fileURL) == row.fingerprint,
      let complete = await reader.completeTranscript(for: identity)
    else { return nil }
    return (rowId, complete.transcript)
  }

  /// Whether a mark at `start..<end` would teach the store, and so skip the same audio in other
  /// episodes: what `teach` would find, short of writing it. False when the episode cannot be
  /// marked or a read fails.
  public func markTeaches(identity: AdSkipEpisodeIdentity, start: Double, end: Double) async -> Bool {
    do {
      guard let episode = try await markableEpisode(identity),
        let span = ListenerMarks.teachingSpan(
          start: start, end: end, beside: try await servedAdSpans(rowId: episode.rowId))
      else { return false }
      let audio = try await loadedAudioLibrary()
      guard
        let print = audio.audioPrint(of: identity)?.slice(
          from: AudioPrint.frame(atTime: span.start), to: AudioPrint.frame(atTime: span.end))
      else { return false }
      return print.isEmpty == false
    } catch {
      return false
    }
  }

  /// Teaches the store a confirmed creative for a mark at `start..<end` and returns its id, or nil
  /// when the mark teaches nothing: its span (`ListenerMarks.teachingSpan`) is too short, or the
  /// episode has no audio print of it, which is what reaches other episodes (`ConfirmedReach`).
  private func teach(
    _ identity: AdSkipEpisodeIdentity, rowId: Int64, start: Double, end: Double,
    transcript: Transcript
  ) async throws -> Int64? {
    // The mark's own span, or, when that is too short to teach, joined to the ad it abuts. Only the
    // stored rows are used, not the shown ones: the player's edge snapping is not the audio.
    guard
      let span = ListenerMarks.teachingSpan(
        start: start, end: end, beside: try await servedAdSpans(rowId: rowId))
    else { return nil }
    let key = identity.episodeKey
    let audio = try await loadedAudioLibrary()
    guard
      let print = audio.audioPrint(of: identity)?.slice(
        from: AudioPrint.frame(atTime: span.start), to: AudioPrint.frame(atTime: span.end)),
      print.isEmpty == false
    else { return nil }
    let teachers = (lastEpisodeGroups?.members(of: key) ?? [key]).union(audio.groups[key] ?? [key])
    guard
      let creative = ListenerMarks.creative(
        from: PreparedTranscript(transcript: transcript, silences: []), start: span.start,
        end: span.end, teachers: teachers)
    else { return nil }
    var insertion = NewAdSignatureCreative(creative, lastSeen: dependencies.now())
    insertion.audioPrint = print.data
    // An Undo of this ad in this group left tombstones that would veto the mark's own creative
    // elsewhere. The listener has now said it is an ad. Another episode's tombstone stands.
    let undone = try await dependencies.signatures.allCreatives().filter {
      $0.kind == .tombstone && $0.teachers.isEmpty == false
        && $0.teachers.isSubset(of: Set(teachers.map(\.rawValue)))
        && $0.startTime < span.end && span.start < $0.endTime
    }.map(\.id)
    return try await dependencies.signatures.apply(
      AdSignatureStoreChange(deletions: Set(undone), insertions: [insertion])
    ).first
  }

  /// A creative with a print changes the audio library, and what the library finds changes other
  /// episodes' ranges. The recompute runs on battery, as the listener asked for it: confirmed
  /// reach needs only prints, so it transcribes nothing.
  private func didTeach() {
    plans.invalidateAudioPlans()
    isRecomputePending = true
    isListenerRecomputeOwed = true
  }

  /// Teaches, once, each mark made under an earlier teaching revision, which taught nothing
  /// shorter than 15 s, and raises it to the current one. A mark whose episode cannot be read now
  /// is left for a later launch. Returns false when a read or write failed.
  func reteachMarks() async -> Bool {
    do {
      let awaiting = try await dependencies.episodes.marksAwaitingTeaching()
      guard awaiting.isEmpty == false else { return true }
      let rows = Dictionary(
        try await dependencies.episodes.allEpisodes().compactMap { row in row.id.map { ($0, row) } },
        uniquingKeysWith: { first, _ in first })
      var taught = false
      for (episodeId, mark) in awaiting {
        guard let row = rows[episodeId] else { continue }
        var creativeId: Int64?
        if mark.creativeId == nil {
          guard let episode = try await markableEpisode(row.identity) else { continue }
          creativeId = try await teach(
            row.identity, rowId: episode.rowId, start: mark.startTime, end: mark.endTime,
            transcript: episode.transcript)
        }
        if try await dependencies.episodes.markTaught(id: mark.id, creativeId: creativeId) {
          if creativeId != nil { taught = true }
        } else if let creativeId {
          // The mark went meanwhile; its creative would have nothing to remove it.
          _ = try await dependencies.signatures.apply(AdSignatureStoreChange(deletions: [creativeId]))
        }
      }
      if taught { didTeach() }
      return true
    } catch {
      Self.log.error("Ad-skip mark reteach failed: \(String(describing: type(of: error)), privacy: .public)")
      return false
    }
  }

  /// The stored spans of the episode's ranges that are not the listener's own, which a short mark
  /// may be taught with. Break filler and detected ads cannot be told apart in the stored fields,
  /// so both count.
  private func servedAdSpans(rowId: Int64) async throws -> [TimeSpan] {
    try await dependencies.episodes.ranges(forEpisodeId: rowId)
      .filter { $0.fromListener == false && AdSkipRules.servedRevisions.contains($0.rulesRevision) }
      .map { TimeSpan(start: $0.startTime, end: $0.endTime) }
  }

  private struct MarkEpisodeGone: Error {}
}

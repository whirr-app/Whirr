import AdSkip
import Foundation
import Persistence

/// The worker's half of Undo: tombstones the range so it is never a hit again, drops what the
/// store taught for it, and owes a recompute.
extension AdSkipCoordinator {

  // MARK: - Worker

  /// Applies queued undos in one signature-store change. Returns true when anything was applied,
  /// in which case the caller recomputes before analysing further. The player has already
  /// forgotten the receipt, so an undo leaves the queue only once applied: one whose episode is
  /// waiting to be analysed again stays, and a failed read puts every unapplied undo back.
  func applyPendingUndos() async throws -> Bool {
    guard pendingUndos.isEmpty == false else { return false }
    let undos = pendingUndos
    pendingUndos = []
    var waiting: [PendingUndo] = []
    var deletions: Set<Int64> = []
    var insertions: [NewAdSignatureCreative] = []
    let now = dependencies.now()
    // Read once, and only when an undone range names an ad. A confirmed ad, which a listener's
    // mark taught, is never deleted by an undo.
    var census: CreativeCensus?
    var suppressed = false
    do {
      for undo in undos {
        let outcome = try await applyUndo(undo, census: census, now: now)
        census = outcome.census ?? census
        if let kept = outcome.waiting { waiting.append(kept) }
        deletions.formUnion(outcome.deletions)
        insertions += outcome.insertions
        suppressed = suppressed || outcome.suppressed
      }
      if deletions.isEmpty == false || insertions.isEmpty == false {
        _ = try await dependencies.signatures.apply(
          AdSignatureStoreChange(deletions: deletions, insertions: insertions))
      }
    } catch {
      pendingUndos = undos + pendingUndos
      throw error
    }
    pendingUndos = waiting + pendingUndos
    return deletions.isEmpty == false || insertions.isEmpty == false || suppressed
  }

  /// One undo: the row and transcript it reads, then the store changes its ranges make. Returns
  /// it as waiting when its episode is not analysed yet or its transcript cannot be read.
  private func applyUndo(
    _ undo: PendingUndo, census: CreativeCensus?, now: Date
  ) async throws -> UndoOutcome {
    // An episode no longer downloaded has nothing left to skip.
    guard currentLocalEpisodes[undo.identity] != nil else { return UndoOutcome() }
    guard let row = try await dependencies.episodes.episode(for: undo.identity),
      row.state == .analysed, let rowId = row.id
    else { return UndoOutcome(waiting: undo) }
    guard let name = row.transcriptFileName,
      let stored = try? dependencies.transcripts.read(fileName: name)
    else {
      // The recompute finds the transcript unreadable and has the episode analysed again.
      isRecomputePending = true
      return UndoOutcome(waiting: undo)
    }
    // From the index view: a tombstone must name only shingles the library can match. A sting
    // segment no stage-1 window reaches holds none, so its covered words hold the undo. A
    // post-roll tail's words are never in the index; its tombstone is the covered words the
    // index does not hold, which is what drops the tail candidate.
    let views = TranscriptViews(
      transcript: stored.transcript, silences: stored.pipelineSilences,
      coverage: stored.coverageSpans, stageOne: try await stageOneWindows(of: row))
    let undone = try await undoneRows(of: undo, rowId: rowId)
    return try await signatureChanges(
      of: undo, undone: undone, row: row, rowId: rowId, stored: stored, views: views,
      census: census, now: now)
  }

  /// The rows an undo covers, other than the listener's own: those an undo from the transcript
  /// deleted and carried, or those the player's range overlaps.
  private func undoneRows(of undo: PendingUndo, rowId: Int64) async throws -> [AdSkipRange] {
    // An undo from the transcript has already deleted its rows and carries them. A range the
    // listener marked is theirs to remove, not an undo's to tombstone.
    if let removed = undo.removed {
      return removed.filter { $0.fromListener == false }
    }
    return try await dependencies.episodes.ranges(forEpisodeId: rowId).filter {
      $0.fromListener == false && $0.startTime < undo.end && undo.start < $0.endTime
    }
  }

  /// The store changes an undone range makes: the confirmed matches it suppresses, the tombstones
  /// it stores and the creatives it lets go.
  private func signatureChanges(
    of undo: PendingUndo, undone: [AdSkipRange], row: AdSkipEpisodeRecord, rowId: Int64,
    stored: StoredTranscript, views: TranscriptViews, census: CreativeCensus?, now: Date
  ) async throws -> UndoOutcome {
    var outcome = UndoOutcome()
    let teachers: Set<EpisodeKey> = [undo.identity.episodeKey]
    // A confirmed ad's match, served by its audio alone, is not matched here again. Its creative
    // stays: the episode that taught it still serves it.
    let undoneCreatives = Set(undone.compactMap(\.creativeId))
    if undoneCreatives.isEmpty == false {
      let census = try await creativeCensus(census)
      outcome.census = census
      if try await dependencies.episodes.suppressConfirmed(
        episodeId: rowId, creativeIds: undoneCreatives.intersection(census.confirmedAds),
        createdAt: now)
      {
        outcome.suppressed = true
      }
    }
    // A host read's words are in neither view; its tombstone comes from the listener's
    // transcript, and with that gone the range goes too.
    if undone.contains(where: \.fromHostRead),
      let tombstone = await hostReadTombstone(
        for: row, silences: stored.pipelineSilences, index: views.index, start: undo.start,
        end: undo.end)
    {
      outcome.insertions.append(NewAdSignatureCreative(tombstone, lastSeen: now))
    }
    guard undone.contains(where: { $0.fromHostRead == false }) else { return outcome }
    if let tombstone = mainTombstone(of: undo, undone: undone, views: views, teachers: teachers) {
      outcome.insertions.append(NewAdSignatureCreative(tombstone, lastSeen: now))
    }
    // An ad more than one episode taught may hold a break's other advertisements, so it stays;
    // the tombstone vetoes the undone hashes before the ad is asked.
    for creative in undone.compactMap(\.creativeId) {
      let census = try await creativeCensus(outcome.census)
      outcome.census = census
      if isDeletable(creative, census: census) { outcome.deletions.insert(creative) }
    }
    return outcome
  }

  /// The main tombstone for an undone range: a post-roll tail's covered words, else the index's,
  /// else the covered words the index does not hold.
  private func mainTombstone(
    of undo: PendingUndo, undone: [AdSkipRange], views: TranscriptViews, teachers: Set<EpisodeKey>
  ) -> NewSignatureCreative? {
    let tail =
      undone.contains(where: \.fromTail)
      ? PostRollTail.tombstone(
        covered: views.covered, index: views.index, start: undo.start, end: undo.end,
        teachers: teachers) : nil
    return tail
      ?? SignatureStore.tombstone(
        from: views.index, start: undo.start, end: undo.end, teachers: teachers)
      ?? SignatureStore.tombstone(
        from: views.covered, start: undo.start, end: undo.end, teachers: teachers)
  }

  /// The census, read from the store the first time this pass needs it.
  private func creativeCensus(_ census: CreativeCensus?) async throws -> CreativeCensus {
    if let census { return census }
    let stored = try await dependencies.signatures.allCreatives()
    return CreativeCensus(
      confirmedAds: Set(stored.filter(\.confirmed).map(\.id)),
      teacherCounts: Dictionary(
        stored.map { ($0.id, $0.teachers.count) }, uniquingKeysWith: { first, _ in first }))
  }

  /// Whether an undone creative can go: a confirmed ad stays, and so does an ad more than one
  /// episode taught.
  private func isDeletable(_ creative: Int64, census: CreativeCensus) -> Bool {
    census.confirmedAds.contains(creative) == false && (census.teacherCounts[creative] ?? 0) <= 1
  }
}

/// The signature store's confirmed ids and teacher counts, read once for an undo pass.
private struct CreativeCensus {
  var confirmedAds: Set<Int64>
  var teacherCounts: [Int64: Int]
}

/// What applying one undo left: the undo to keep for the next pass if it did not land, the
/// creatives to delete, the tombstones to store, and the census it read.
private struct UndoOutcome {
  var waiting: PendingUndo? = nil
  var deletions: Set<Int64> = []
  var insertions: [NewAdSignatureCreative] = []
  var census: CreativeCensus? = nil
  var suppressed = false
}

struct PendingUndo: Sendable {
  let identity: AdSkipEpisodeIdentity
  let start: Double
  let end: Double
  /// The rows an undo from the transcript deleted before it was queued, which the store no longer
  /// holds. Nil for the player's Undo, which finds its rows by overlap.
  var removed: [AdSkipRange]? = nil
}

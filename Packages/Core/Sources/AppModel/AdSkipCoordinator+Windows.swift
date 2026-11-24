import AdSkip
import Foundation
import Persistence

/// Work execution on the worker actor: one decode or one transcript write at a time, the
/// unreadable files it drops, and the row's two word views. Queue selection is `+Queue`, stage-1
/// planning is `+StageOne`.
extension AdSkipCoordinator {

  /// Deletes rows whose files could not be read, so they are analysed again on the next pass; a
  /// second failure waits for the local set to change.
  func discardUnreadable(_ identities: [AdSkipEpisodeIdentity]) async throws {
    let names = try await dependencies.episodes.deleteEpisodes(identities)
    dependencies.transcripts.delete(fileNames: names)
    for identity in identities where rereadTranscripts.insert(identity).inserted == false {
      noteUnreadable(identity)
    }
    plans.invalidateAudioPlans()
    await queue.requestPass()
  }

  /// Leaves the episode out of the queue until the local set changes. Signalled, since no settled
  /// state changes: an open card would otherwise keep saying the episode is queued.
  private func noteUnreadable(_ identity: AdSkipEpisodeIdentity) {
    unreadableFiles.insert(identity)
    statusChanges.signal()
  }

  // MARK: - Work

  /// Runs one unit. Returns true when something was stored.
  func perform(_ work: Work) async throws -> Bool {
    switch work {
    case .decode(let episode, let row): try await decode(episode, row: row)
    case .transcribe(let episode, let row, let windows):
      try await transcribe(episode, row: row, windows: windows)
    }
  }

  /// Decodes the file once for its silences and audio print. A new row is saved `.decoded` with an
  /// empty transcript; a row transcribed in full before audio prints keeps its transcript and
  /// ranges and gains the print.
  private func decode(_ episode: AdSkipLocalEpisode, row: AdSkipEpisodeRecord?) async throws -> Bool {
    guard let fingerprint = dependencies.fingerprinting.fingerprint(ofFileAt: episode.fileURL) else {
      noteUnreadable(episode.identity)
      return false
    }
    let url = episode.fileURL
    let printer = dependencies.audioPrinter
    guard
      let result = await run(
        episode, fingerprint: fingerprint,
        {
          .decoded(try await printer.decode(fileAt: url))
        })
    else { return false }
    guard case .success(.decoded(let decoded)) = result else {
      try await saveFailure(episode, fingerprint: fingerprint, result: result)
      return false
    }

    let printName = try dependencies.transcripts.writeAudioPrint(
      littleEndianWords: decoded.audioPrint.data)
    var written = [printName]
    do {
      let record: AdSkipEpisodeRecord
      var ranges: [AdSkipRange] = []
      if let row, row.state == .analysed, row.transcriptFileName != nil, row.fingerprint == fingerprint {
        var upgraded = row
        upgraded.audioPrintFileName = printName
        record = upgraded
        if let id = row.id { ranges = try await dependencies.episodes.ranges(forEpisodeId: id) }
      } else {
        let transcriptName = try dependencies.transcripts.write(
          StoredTranscript(
            words: [], silences: decoded.silences.map { StoredSilence(start: $0.start, end: $0.end) },
            duration: decoded.duration, coverage: []))
        written.append(transcriptName)
        plans.transcriptCoverages[transcriptName] = TranscriptCoverage(
          duration: decoded.duration, spans: [], silences: decoded.silences)
        record = newRecord(
          episode, fingerprint: fingerprint, state: .decoded, transcriptFileName: transcriptName,
          audioPrintFileName: printName)
      }
      let saved = try await dependencies.episodes.save(record, ranges: ranges)
      dependencies.transcripts.delete(fileNames: saved.replacedFileNames)
    } catch {
      dependencies.transcripts.delete(fileNames: written)
      throw error
    }
    plans.invalidateAudioPlans()
    return true
  }

  /// Transcribes the missing windows and merges their words into a new transcript file, which the
  /// row then names. The state and ranges are kept: the recompute decides both.
  private func transcribe(
    _ episode: AdSkipLocalEpisode, row: AdSkipEpisodeRecord, windows: [TimeSpan]
  ) async throws -> Bool {
    // Reached, whatever comes of it, so the next round counts against the limit.
    plans.stageTwoAwaiting.remove(episode.identity)
    guard let fingerprint = dependencies.fingerprinting.fingerprint(ofFileAt: episode.fileURL) else {
      noteUnreadable(episode.identity)
      return false
    }
    guard let name = row.transcriptFileName,
      let previous = try? dependencies.transcripts.read(fileName: name)
    else {
      try await discardUnreadable([episode.identity])
      return false
    }
    let url = episode.fileURL
    let transcriber = dependencies.transcriber
    guard
      let result = await run(
        episode, fingerprint: fingerprint,
        {
          .transcribed(try await transcriber.transcript(ofFileAt: url, windows: windows))
        })
    else { return false }
    guard case .success(.transcribed(let transcript)) = result else {
      try await saveFailure(episode, fingerprint: fingerprint, result: result)
      return false
    }

    // Windows are disjoint from the coverage and the slice rule keeps each word in one window, so
    // nothing is transcribed twice.
    let words =
      (previous.words
      + transcript.words.map { StoredTranscriptWord(text: $0.text, start: $0.start, end: $0.end) })
      .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    let coverage = TranscriptionWindows.union(previous.coverageSpans + windows)
    let merged = StoredTranscript(
      words: words, silences: previous.silences, duration: previous.duration,
      coverage: coverage.map { StoredTimeSpan(start: $0.start, end: $0.end) })
    let newName = try dependencies.transcripts.write(merged)
    do {
      var updated = row
      updated.transcriptFileName = newName
      updated.transcriberRevision = dependencies.transcriberRevision
      updated.analysedAt = dependencies.now()
      var ranges: [AdSkipRange] = []
      if let id = row.id { ranges = try await dependencies.episodes.ranges(forEpisodeId: id) }
      let saved = try await dependencies.episodes.save(updated, ranges: ranges)
      dependencies.transcripts.delete(fileNames: saved.replacedFileNames)
    } catch {
      dependencies.transcripts.delete(fileNames: [newName])
      throw error
    }
    plans.transcriptCoverages[newName] = TranscriptCoverage(
      duration: previous.duration, spans: coverage, silences: previous.pipelineSilences)
    return true
  }

  /// Runs one adapter call as the cancellable in-flight task. Nil when the result no longer counts:
  /// cancelled, deferred, or the file changed or stopped being wanted meanwhile.
  private func run(
    _ episode: AdSkipLocalEpisode, fingerprint: AdSkipFileFingerprint,
    _ body: @escaping @Sendable () async throws -> WorkOutcome
  ) async -> Result<WorkOutcome, Error>? {
    let task = Task(priority: .utility) {
      let outcome = try await body()
      try Task.checkCancellation()
      return outcome
    }
    inFlight = (episode.identity, task)
    underAnalysis = episode.identity
    let result = await task.result
    inFlight = nil

    // Anything may have changed meanwhile: only a still-wanted, unchanged file counts.
    let url = episode.fileURL
    guard isEnabled == true, let current = localEpisodes?[episode.identity],
      Self.isAnalysable(current), current.fileURL == url,
      dependencies.fingerprinting.fingerprint(ofFileAt: url) == fingerprint
    else { return nil }
    switch result {
    // A cancelled adapter call can report an error of its own in place of `CancellationError`;
    // that is the interruption, not a fault in the file.
    case .failure(let error) where task.isCancelled || error is CancellationError:
      return nil
    case .failure(let error) where error is AdSkipAnalysisDeferred:
      isDeferred = true
      underAnalysis = nil
      return nil
    default:
      return result
    }
  }

  /// Records the episode as failed, dropping its files; a later transcriber retries it.
  private func saveFailure(
    _ episode: AdSkipLocalEpisode, fingerprint: AdSkipFileFingerprint,
    result: Result<WorkOutcome, Error>
  ) async throws {
    if case .failure(let error) = result {
      Self.log.notice(
        "Ad-skip analysis failed: \(String(describing: type(of: error)), privacy: .public)")
    }
    let saved = try await dependencies.episodes.save(
      newRecord(
        episode, fingerprint: fingerprint, state: .failed, transcriptFileName: nil,
        audioPrintFileName: nil),
      ranges: [])
    dependencies.transcripts.delete(fileNames: saved.replacedFileNames)
    plans.invalidateAudioPlans()
    // No recompute follows a failure, so nothing else would tell an open card.
    statusChanges.signal()
  }

  private func newRecord(
    _ episode: AdSkipLocalEpisode, fingerprint: AdSkipFileFingerprint,
    state: AdSkipAnalysisState, transcriptFileName: String?, audioPrintFileName: String?
  ) -> AdSkipEpisodeRecord {
    AdSkipEpisodeRecord(
      source: episode.identity.source, accountId: episode.identity.accountId,
      itemID: episode.identity.itemID, episodeID: episode.identity.episodeID,
      fileByteSize: fingerprint.byteSize, fileModificationTime: fingerprint.modificationTime,
      transcriberRevision: dependencies.transcriberRevision, rulesRevision: AdSkipRules.revision,
      state: state, transcriptFileName: transcriptFileName, analysedAt: dependencies.now(),
      audioPrintFileName: audioPrintFileName)
  }

  // MARK: - Views

  /// The row's two word views, or nil when its transcript cannot be read.
  func views(of row: AdSkipEpisodeRecord, stageOne: [TimeSpan]?) -> TranscriptViews? {
    guard let name = row.transcriptFileName,
      let stored = try? dependencies.transcripts.read(fileName: name)
    else { return nil }
    return TranscriptViews(
      transcript: stored.transcript, silences: stored.pipelineSilences,
      coverage: stored.coverageSpans, stageOne: stageOne)
  }
}

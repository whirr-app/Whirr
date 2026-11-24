import AdSkip
import Foundation
import Persistence

/// A downloaded file's identity for ad skipping. Ranges and transcripts belong to the file they
/// were computed from, so a re-download with different dynamic ads is analysed again.
public struct AdSkipFileFingerprint: Sendable, Equatable, Hashable {
  public var byteSize: Int64
  public var modificationTime: Double

  public init(byteSize: Int64, modificationTime: Double) {
    self.byteSize = byteSize
    self.modificationTime = modificationTime
  }
}

public protocol AdSkipFileFingerprinting: Sendable {
  /// Nil when the file is missing or is not a regular file.
  func fingerprint(ofFileAt url: URL) -> AdSkipFileFingerprint?
}

/// Reads the byte size and modification date. The date is a file timestamp API, declared in the
/// App's privacy manifest under reason C617.1 (files inside the app container).
public struct FileSystemAdSkipFingerprinting: AdSkipFileFingerprinting {
  public init() {}

  public func fingerprint(ofFileAt url: URL) -> AdSkipFileFingerprint? {
    guard
      let values = try? url.resourceValues(forKeys: [
        .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
      ]),
      values.isRegularFile == true, let size = values.fileSize,
      let modified = values.contentModificationDate
    else { return nil }
    return AdSkipFileFingerprint(
      byteSize: Int64(size), modificationTime: modified.timeIntervalSince1970)
  }
}

extension AdSkipEpisodeIdentity {
  /// The opaque key the pipeline and the signature store's teacher rows use.
  var episodeKey: EpisodeKey { EpisodeKey(teacherKey) }
}

extension AdSkipEpisodeRecord {
  var fingerprint: AdSkipFileFingerprint {
    AdSkipFileFingerprint(byteSize: fileByteSize, modificationTime: fileModificationTime)
  }
}

// MARK: - Conversions between Persistence's values and the pipeline's

extension StoredTranscript {
  init(_ transcript: Transcript, silences: [Silence]) {
    self.init(
      words: transcript.words.map { StoredTranscriptWord(text: $0.text, start: $0.start, end: $0.end) },
      silences: silences.map { StoredSilence(start: $0.start, end: $0.end) },
      duration: transcript.duration)
  }

  var transcript: Transcript {
    Transcript(
      words: words.map { TranscriptWord(text: $0.text, start: $0.start, end: $0.end) },
      duration: duration)
  }

  var pipelineSilences: [Silence] {
    silences.map { Silence(start: $0.start, end: $0.end) }
  }

  var coverageSpans: [TimeSpan] {
    coverage.map { TimeSpan(start: $0.start, end: $0.end) }
  }
}

extension SignatureCreative {
  init(_ stored: StoredAdSignatureCreative) {
    self.init(
      id: stored.id,
      kind: stored.kind == .learned ? .learned : .tombstone,
      lastSeen: stored.lastSeen,
      start: stored.startTime,
      end: stored.endTime,
      teachers: Set(stored.teachers.map(EpisodeKey.init)),
      hashes: stored.hashes,
      confirmed: stored.confirmed)
  }
}

extension NewAdSignatureCreative {
  init(_ creative: AdSkip.NewSignatureCreative, lastSeen: Date) {
    self.init(
      kind: creative.kind == .learned ? .learned : .tombstone,
      lastSeen: lastSeen,
      startTime: creative.start,
      endTime: creative.end,
      teachers: Set(creative.teachers.map(\.rawValue)),
      hashes: creative.hashes,
      confirmed: creative.confirmed)
  }
}

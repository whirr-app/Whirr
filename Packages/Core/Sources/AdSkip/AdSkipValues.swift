import Foundation

// The pure ad-skip pipeline: a port of rules developed and frozen in a separate research harness,
// scoped to inserted ads. Every constant and comparison is held to that harness's scripts
// (`repeatall.py` for repetition, `prep.py` for steps, `arbiter.py` for the veto and `replay.py`
// for the store); its parity run must reproduce them, so change the rules there first.

/// The rules and model revision recorded with each analysed episode. A change re-scores every
/// on-device episode from its stored transcript.
public enum AdSkipRules {
  /// 2: a range's end runs on to a nearby pause (`PlaybackEdges`).
  /// 3: a range's start runs back to a sponsor phrase that opens it (`SponsorPhraseStart`).
  /// 4: only the stretches whose audio recurs are transcribed and indexed.
  /// 5: "powered by" is a sponsor phrase trigger.
  /// 6: sponsor phrase forms mined from the labelled corpus: an open subject, "brought to us by",
  ///    "support for … comes from", "thank our … partner" and "for sponsoring".
  /// 7: a range is served across the silences on either side of it (`PlaybackEdges`).
  /// 8: the show's name is a sponsor phrase subject, and a second phrase round runs from a
  ///    phrase-moved start.
  /// 9: a sponsor phrase straight after a recurring sting opens a segment to the next kept range or
  ///    sting (`StingSegment`), and stage 2 transcribes just after each sting.
  /// 10: ranges that overlap are served as their union, not cut at the later one's start.
  /// 11: the first word of a transcribed stretch opens a sentence, so a sponsor phrase straight
  ///     after a sting is seen however the stretch before it ended.
  /// 12: a candidate the arbiter drops is kept when another show's audio covers 15 s of it
  ///     (`CrossShowEvidence`), and a gap of up to 60 s between two served spans is served with
  ///     them (`PlaybackEdges.breakFills`).
  /// 13: a one-off post-roll after a stitch silence near the end of the file is transcribed and
  ///     kept at its own cut (`PostRollTail`).
  /// 14: host reads in an episode the listener has transcribed in full are served beside the
  ///     shipped ranges (`HostReadSpans`).
  public static let revision = 14

  /// Revisions playback still serves while the current one is being computed. Each differs from
  /// the next only by what the later revision adds (see the list above), so they are served until
  /// the recompute replaces them.
  public static let servedRevisions: Set<Int> = [6, 7, 8, 9, 10, 11, 12, 13, 14]
}

/// One transcribed word, with its time range in seconds from the start of the file.
public struct TranscriptWord: Sendable, Equatable, Codable {
  public let text: String
  public let start: Double
  public let end: Double

  public init(text: String, start: Double, end: Double) {
    self.text = text
    self.start = start
    self.end = end
  }
}

/// A transcript as the transcriber produced it: raw word text, in time order with finite times. The
/// rules assume that order, as the harness did; the transcriber adapter guarantees it.
public struct Transcript: Sendable, Equatable, Codable {
  public let words: [TranscriptWord]
  /// Audio duration in seconds; the arbiter's last step is truncated here.
  public let duration: Double

  public init(words: [TranscriptWord], duration: Double) {
    self.words = words
    self.duration = duration
  }
}

/// A stretch of audio below the silence threshold, in seconds. Silences are in time order.
public struct Silence: Sendable, Equatable, Codable {
  public let start: Double
  public let end: Double

  public init(start: Double, end: Double) {
    self.start = start
    self.end = end
  }
}

/// An opaque, stable episode identity. The coordinator composes it from source, account and
/// episode IDs; this target only compares keys.
public struct EpisodeKey: Hashable, Comparable, Sendable, Codable {
  public let rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public static func < (lhs: EpisodeKey, rhs: EpisodeKey) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

/// A range the repetition stage proposes, before the arbiter.
public struct CandidateRange: Sendable, Equatable {
  public let start: Double
  public let end: Double

  public init(start: Double, end: Double) {
    self.start = start
    self.end = end
  }
}

/// A range the arbiter kept: what playback skips.
public struct KeptRange: Sendable, Equatable {
  public let start: Double
  public let end: Double
  /// Mean P(ad) over the range's steps.
  public let meanAdProbability: Double
  /// True when no transcript word starts after `end`, so skipping it finishes the item. Under
  /// partial coverage, `TranscriptViews.confirmingEndsItem` also asks that the coverage reach the
  /// end of the file.
  public let endsItem: Bool

  public init(start: Double, end: Double, meanAdProbability: Double, endsItem: Bool) {
    self.start = start
    self.end = end
    self.meanAdProbability = meanAdProbability
    self.endsItem = endsItem
  }
}

// MARK: - Adapters the App implements

/// Thrown by an adapter when analysis cannot run yet on this device, for example while the speech
/// asset is not installed. Not a failure of the file: the coordinator retries once analysis is
/// allowed again, rather than recording the episode as failed.
public struct AdSkipAnalysisDeferred: Error, Sendable, Equatable {
  public init() {}
}

public protocol EpisodeTranscribing: Sendable {
  /// The words of `windows`: each window's padded slice
  /// (`TranscriptionWindows.slice(for:duration:)`) is transcribed from the downloaded file on the
  /// file's clock, and only the words the slice rule keeps
  /// (`TranscriptionWindows.words(_:keptBy:)`) are returned, in time order. The duration is the
  /// file's.
  func transcript(ofFileAt url: URL, windows: [TimeSpan]) async throws -> Transcript
}

/// One decode of a downloaded file: its silences and its audio print, sharing one clock with the
/// transcriber.
public struct DecodedAudio: Sendable, Equatable {
  /// At the harness's threshold: below -35 dBFS for at least 0.3 s, at the file's own sample rate.
  public let silences: [Silence]
  public let audioPrint: AudioPrint
  /// The file's duration in seconds, as the transcriber reports it.
  public let duration: Double

  public init(silences: [Silence], audioPrint: AudioPrint, duration: Double) {
    self.silences = silences
    self.audioPrint = audioPrint
    self.duration = duration
  }
}

public protocol AudioPrinting: Sendable {
  /// Decodes the whole file once for its silences and audio print. No speech model runs.
  func decode(fileAt url: URL) async throws -> DecodedAudio
}

public protocol AdStepScoring: Sendable {
  /// P(ad) for each step text, index-aligned with the input.
  func adProbabilities(forStepTexts texts: [String]) async throws -> [Double]
}

// The plan book's values: the audio library of prints, each library's retained and stage-one
// plans, and a transcript file's cached coverage.

import AdSkip
import Foundation
import Persistence

/// Every local episode's audio print and every learned creative's, memory-mapped. Built once per
/// change to the set of prints.
struct AudioLibrary {
  var references: [AudioRecurrence.Reference] = []
  /// Episode rows by their index in `references`; creatives follow the episodes.
  var queryIndex: [AdSkipEpisodeIdentity: Int] = [:]
  /// Each reference's print and keys as one line, in library order: what tells a kept reference
  /// from an added, removed or re-keyed one.
  var entries: [String] = []
  /// Each episode reference's own key and show, in library order.
  var episodeKeys: [EpisodeKey] = []
  var shows: [String] = []
  /// The show each episode was planned under: a show joined or split since replans the library.
  var showByEpisode: [AdSkipEpisodeIdentity: String] = [:]
  /// Names every input of a stage-1 query but the query's own position, in order: each
  /// reference's print and the keys it may not match, and the matching and windowing rules.
  /// Libraries with one key plan every episode identically, so a stored plan is reused only under
  /// it; it may have been carried from an earlier library rather than queried.
  var key = ""
  /// Each printed episode's linked group, and the keys each printed ad was given under them.
  var groups: [EpisodeKey: Set<EpisodeKey>] = [:]
  var creativeKeys: [Int64: Set<EpisodeKey>] = [:]
  /// The prints of the creatives a listener's mark confirmed (`ConfirmedReach`).
  var confirmedPrints: [Int64: AudioPrint] = [:]

  func audioPrint(of identity: AdSkipEpisodeIdentity) -> AudioPrint? {
    queryIndex[identity].map { references[$0].print }
  }

  /// The query's alignments with other episodes, sorted: the audio-edge evidence. A learned
  /// creative is not evidence: it holds the ad alone, never what plays beside it.
  func audioEdges(of query: Int, alignments: [AudioRecurrence.Alignment]) -> [TimeSpan] {
    let spans = alignments.filter { $0.reference < queryIndex.count }.map(\.span)
    return Set(spans).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
  }

  /// The query's alignments with other episodes of its own show, sorted: the post-roll tail
  /// trigger's evidence that a stretch is the show's outro or credits. Linked copies never
  /// align, so they are not among them.
  func sameShow(of query: Int, alignments: [AudioRecurrence.Alignment]) -> [TimeSpan] {
    let spans = alignments.filter {
      $0.reference < queryIndex.count && shows[$0.reference] == shows[query]
    }.map(\.span)
    return Set(spans).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
  }

  /// The query's alignments with episodes of another show, each with that episode, sorted. The
  /// recompute drops a rerun's, which it alone can tell.
  func crossShow(of query: Int, alignments: [AudioRecurrence.Alignment]) -> [CrossShowAlignment] {
    let found = alignments.filter {
      $0.reference < queryIndex.count && shows[$0.reference] != shows[query]
    }.map { CrossShowAlignment(span: $0.span, episode: episodeKeys[$0.reference]) }
    return Set(found).sorted {
      ($0.span.start, $0.span.end, $0.episode) < ($1.span.start, $1.span.end, $1.episode)
    }
  }
}

/// Where an episode's audio aligns with an episode of another show, and that episode.
struct CrossShowAlignment: Hashable, Sendable {
  var span: TimeSpan
  var episode: EpisodeKey
}

/// An episode's stage-1 plan: its transcription windows, the audio-edge evidence the same query
/// found, the part of it with other shows, and the part with its own show.
struct StageOnePlan: Equatable, Sendable {
  var windows: [TimeSpan]
  var audioEdges: [TimeSpan]
  var crossShow: [CrossShowAlignment] = []
  var sameShowEdges: [TimeSpan] = []
}

/// A transcript file's duration, coverage and silences, cached by file name so the queue does
/// not decode every transcript on every pass. A file name is never reused.
struct TranscriptCoverage: Sendable {
  let duration: Double
  let spans: [TimeSpan]
  let silences: [Silence]
}

/// One library's plans, kept from the moment its prints changed until the next library loads.
struct RetainedPlans {
  /// The library's references in order, as `AudioLibrary.entries`.
  var entries: [String]
  /// Each episode's own entry, to tell a kept episode from one whose print or keys changed.
  var entryByEpisode: [AdSkipEpisodeIdentity: String]
  var plans: [AdSkipEpisodeIdentity: StageOnePlan]
}

import Foundation

/// A stretch of an episode, in seconds.
public struct TimeSpan: Sendable, Equatable, Hashable, Codable {
  public let start: Double
  public let end: Double

  public init(start: Double, end: Double) {
    self.start = start
    self.end = end
  }

  public var duration: Double { end - start }
}

/// Which seconds of an episode the speech model hears: a port of `audiocand.py` `build`
/// (stage 1), its stage-2 windows, and `fidelity.py`'s slice rule. Pure; the coordinator asks it
/// what an episode still needs.
public enum TranscriptionWindows {
  /// Audio runs closer than this merge before the floor (`repeatall.py` `MERGE`).
  public static let mergeSeconds = RepetitionStage.mergeSeconds
  /// A merged run shorter than this earns no window (`repeatall.py` `MIN_RUN`).
  public static let minimumRunSeconds = RepetitionStage.minimumRunSeconds
  /// Stage 1 transcribes each surviving run this far either side: a 15 s silence extension plus
  /// the 12.5 s an overlapping step's context reaches.
  public static let marginSeconds = 27.5
  /// Stage 2a: this long before a kept range's start, to look for a sponsor phrase.
  public static let sponsorLookBackSeconds = 92.0
  /// Stage 2b: this long before a sponsor phrase's start, for the silence move and its steps.
  public static let anchorLookBackSeconds = 27.5
  /// Audio transcribed either side of a window, whose words are then dropped.
  public static let padSeconds = 5.0

  /// Stage-1 windows from an episode's audio runs: an optimistic merge across any gap under
  /// `mergeSeconds` (no words exist yet), the floor, then each survivor widened by the margin.
  /// Not clamped to the file, as the harness.
  public static func stageOne(runs: [TimeSpan]) -> [TimeSpan] {
    var merged: [(start: Double, end: Double)] = []
    for run in runs {
      if let last = merged.last, run.start - last.end < mergeSeconds {
        merged[merged.count - 1].end = max(last.end, run.end)
      } else {
        merged.append((run.start, run.end))
      }
    }
    return union(
      merged.filter { $0.end - $0.start >= minimumRunSeconds }.map {
        TimeSpan(start: $0.start - marginSeconds, end: $0.end + marginSeconds)
      })
  }

  /// Stage-2 windows: `[K.start - 92, K.start]` for every kept range,
  /// `[anchor - 27.5, anchor]` for every sponsor-phrase start used, and `[end - 1, end + 10]` after
  /// every sting, for a sponsored segment's opener (`StingSegment`).
  public static func stageTwo(
    keptStarts: [Double], anchors: [Double], stingEnds: [Double] = []
  ) -> [TimeSpan] {
    keptStarts.map { TimeSpan(start: $0 - sponsorLookBackSeconds, end: $0) }
      + anchors.map { TimeSpan(start: $0 - anchorLookBackSeconds, end: $0) }
      + stingEnds.map {
        TimeSpan(
          start: $0 - StingSegment.beforeStingEndSeconds, end: $0 + StingSegment.afterStingSeconds)
      }
  }

  /// `audiocand.py` `union`: sorted, empty spans dropped, touching spans joined.
  public static func union(_ spans: [TimeSpan]) -> [TimeSpan] {
    var out: [TimeSpan] = []
    for span in spans.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) where span.end > span.start {
      if let last = out.last, span.start <= last.end {
        out[out.count - 1] = TimeSpan(start: last.start, end: max(last.end, span.end))
      } else {
        out.append(span)
      }
    }
    return out
  }

  /// `spans` clamped to `[0, duration]`, joined.
  public static func clamped(_ spans: [TimeSpan], duration: Double) -> [TimeSpan] {
    union(spans.map { TimeSpan(start: max(0, $0.start), end: min(duration, $0.end)) })
  }

  /// The parts of `wanted` that `covered` leaves out, dropping slivers shorter than
  /// `minimumSeconds` so float noise at an edge never queues work.
  public static func missing(
    _ wanted: [TimeSpan], covered: [TimeSpan], minimumSeconds: Double = 0.5
  ) -> [TimeSpan] {
    let covered = union(covered)
    var out: [TimeSpan] = []
    for span in union(wanted) {
      var cursor = span.start
      for hole in covered where hole.end > cursor && hole.start < span.end {
        if hole.start > cursor { out.append(TimeSpan(start: cursor, end: hole.start)) }
        cursor = max(cursor, hole.end)
      }
      if cursor < span.end { out.append(TimeSpan(start: cursor, end: span.end)) }
    }
    return out.filter { $0.duration >= minimumSeconds }
  }

  /// Total seconds of `spans` inside `[0, duration]`.
  public static func seconds(_ spans: [TimeSpan], duration: Double) -> Double {
    clamped(spans, duration: duration).reduce(0) { $0 + $1.duration }
  }

  /// The audio to hand the speech model for `window`: padded either side, clamped to the file.
  public static func slice(for window: TimeSpan, duration: Double) -> TimeSpan {
    TimeSpan(start: max(0, window.start - padSeconds), end: min(duration, window.end + padSeconds))
  }

  /// `fidelity.py`'s slice rule: of the words transcribed from a window's padded slice (on the
  /// file clock), those whose midpoint lies in `[window.start, window.end)`.
  public static func words(_ words: [TranscriptWord], keptBy window: TimeSpan) -> [TranscriptWord] {
    words.filter {
      let middle = ($0.start + $0.end) / 2
      return window.start <= middle && middle < window.end
    }
  }

  /// `audiocand.py` `build`'s index rule: the words lying wholly inside a stage-1 window.
  public static func indexWords(_ words: [TranscriptWord], stageOne: [TimeSpan]) -> [TranscriptWord] {
    words.filter { word in stageOne.contains { $0.start <= word.start && word.end <= $0.end } }
  }

  // MARK: - Post-roll tail

  /// A tail silence starts within this many seconds of the end of the file.
  public static let tailSearchSeconds = 120.0
  /// The shortest silence that can be the stitch before an inserted post-roll.
  public static let stitchSeconds = 0.5
  /// The stretch from the silence's end to the end of the file, inclusive.
  public static let tailMinimumSeconds = 10.0
  public static let tailMaximumSeconds = 90.0
  /// A same-show alignment overlapping the stretch by no more than this is its own edge.
  public static let tailSameShowOverlapSeconds = 0.5
  /// The tail window opens this far before its silence: one step plus its context, so a step
  /// overlapping a range from the silence's end hears no word the window left out.
  public static let tailContextSeconds = Arbiter.stepSeconds + Arbiter.contextSeconds

  /// The silence an inserted post-roll may follow, from audio alone: the last silence of at least
  /// `stitchSeconds` that starts in the final `tailSearchSeconds`, whose stretch to the end of the
  /// file is `tailMinimumSeconds` to `tailMaximumSeconds` long and holds none of `sameShow`, the
  /// episode's alignments with other episodes of its show (its outro or credits). Nil when none
  /// does.
  public static func tailSilence(
    silences: [Silence], duration: Double, sameShow: [TimeSpan]
  ) -> Silence? {
    silences.sorted { $0.start < $1.start }.last { silence in
      let stretch = duration - silence.end
      return silence.end - silence.start >= stitchSeconds
        && silence.start >= duration - tailSearchSeconds
        && tailMinimumSeconds <= stretch && stretch <= tailMaximumSeconds
        && sameShow.allSatisfy {
          min($0.end, duration) - max($0.start, silence.end) <= tailSameShowOverlapSeconds
        }
    }
  }

  /// The covered-only window that transcribes the stretch after `silence`.
  public static func tailWindow(after silence: Silence, duration: Double) -> TimeSpan {
    TimeSpan(start: silence.start - tailContextSeconds, end: duration)
  }

  /// Whether `covered` reaches from `time` to the end of the file, allowing
  /// `tolerance` for the file's estimated length.
  public static func covers(
    _ covered: [TimeSpan], from time: Double, toEndOf duration: Double, tolerance: Double = 0.5
  ) -> Bool {
    missing([TimeSpan(start: time, end: duration)], covered: covered, minimumSeconds: tolerance)
      .isEmpty
  }
}

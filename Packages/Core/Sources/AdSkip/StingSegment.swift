import Foundation

/// A sponsored segment opened by the show's break sting: a sponsor phrase whose head starts within
/// `stingGapSeconds` of a short recurring run's end skips from that run to the next kept range or
/// sting. A one-off read several minutes long matches nothing and sits too far before the next
/// kept range for `SponsorPhraseStart`, but the sting before it recurs, so its time is known
/// without transcribing the read.
///
/// Like `SponsorPhraseStart`, playback-only: the store learns the frozen rules' ranges, so a bad
/// segment cannot spread. No arbiter veto applies (it would score the body as programme, and the
/// body is never transcribed); the safety is the sting, the phrase and the cap. Harness twin:
/// ad-harness `Scripts/research/sting/sting.py`, which takes stings from refined audio runs where
/// this uses the stored audio-edge alignments, and tests only a phrase's head against the kept
/// ranges where this tests the whole phrase.
public enum StingSegment {
  /// How far either side of a sting's end a phrase's head may start.
  public static let stingGapSeconds = 2.0
  /// The furthest a segment may run past its phrase's start. With no kept range or sting
  /// before it, there is no segment: a phrase gives a start but no end.
  public static let maximumSegmentSeconds = 360.0
  /// Stage 2 transcribes this long after each sting's end, for the phrase.
  public static let afterStingSeconds = 10.0
  /// …and from this long before it, since a head can start just inside the sting's last frames.
  public static let beforeStingEndSeconds = 1.0

  public struct Segment: Sendable, Equatable {
    public let start: Double
    public let end: Double
    /// The kept range the segment runs into, when that range ends it rather than a sting.
    public let keptIndex: Int?

    public init(start: Double, end: Double, keptIndex: Int?) {
      self.start = start
      self.end = end
      self.keptIndex = keptIndex
    }
  }

  /// Short recurring runs: audio-edge spans merged across gaps under
  /// `RepetitionStage.mergeSeconds`, as stage 1 merges runs, and kept when the merged run is under
  /// `minimumRunSeconds`.
  public static func stings(audioEdges: [TimeSpan]) -> [TimeSpan] {
    var merged: [(start: Double, end: Double)] = []
    for edge in audioEdges.sorted(by: { ($0.start, $0.end) < ($1.start, $1.end) }) {
      if let last = merged.last, edge.start - last.end < RepetitionStage.mergeSeconds {
        merged[merged.count - 1].end = max(last.end, edge.end)
      } else {
        merged.append((edge.start, edge.end))
      }
    }
    return merged.filter { $0.end - $0.start < RepetitionStage.minimumRunSeconds }
      .map { TimeSpan(start: $0.start, end: $0.end) }
  }

  /// One segment per sting a phrase opens. A phrase a kept range overlaps is that range's business:
  /// the matched sponsor's shingles can begin partway through its own opener.
  /// The segment starts at the sting, or where a kept range holding the sting ends, and runs to the
  /// earliest kept-range or sting start after the phrase. A segment holding a tombstoned shingle
  /// is not rebuilt (an Undo of it must stick).
  public static func segments(
    stings: [TimeSpan], kept: [KeptRange], in transcript: PreparedTranscript, showTitle: String?,
    isTombstoned: (UInt64) -> Bool
  ) -> [Segment] {
    var result: [Segment] = []
    var opened: Set<Int> = []
    let anchors = SponsorPhraseStart.anchors(
      in: transcript.words, showTitle: SponsorPhraseStart.titleWords(showTitle))
    for anchor in anchors {
      guard kept.allSatisfy({ !($0.start < anchor.phraseEnd && anchor.start < $0.end) }),
        let index = stings.indices.first(where: { abs(anchor.start - stings[$0].end) <= stingGapSeconds }),
        opened.contains(index) == false
      else { continue }
      let nextKept = kept.indices.filter { kept[$0].start > anchor.phraseEnd }
        .min { kept[$0].start < kept[$1].start }
      let nextSting = stings.map(\.start).filter { $0 > anchor.phraseEnd }.min()
      let end: Double
      let keptIndex: Int?
      if let nextKept, kept[nextKept].start <= nextSting ?? .infinity {
        (end, keptIndex) = (kept[nextKept].start, nextKept)
      } else if let nextSting {
        (end, keptIndex) = (nextSting, nil)
      } else {
        continue
      }
      guard end < anchor.start + maximumSegmentSeconds else { continue }
      let start =
        kept.filter { $0.start <= stings[index].start && stings[index].start < $0.end }
        .map(\.end).max() ?? stings[index].start
      guard start < end,
        !transcript.shingles.contains(where: { $0.start < end && $0.end > start && isTombstoned($0.hash) })
      else { continue }
      opened.insert(index)
      result.append(Segment(start: start, end: end, keptIndex: keptIndex))
    }
    return result
  }
}

import Foundation

/// Host-read sponsor spots in an episode with a whole transcript, anchored on the call to action.
/// A host read is recorded once, so repetition never proposes it; what marks it is the classifier
/// being sure of the stretch where the host gives the sponsor's address. Harness twin: ad-harness
/// `Scripts/research/hostread/hostread.py` with `--anchors`, frozen for hold-out 7.
///
/// Per call-to-action run, the span opens at the sentence first naming the sponsor, or at a
/// sponsor phrase, within `lookBackSeconds` before the run, and closes at the run's last word. The
/// address itself names the sponsor, so a run nothing earlier opens starts at the address's own
/// sentence. The caller applies the arbiter's veto and lays the spans over the shipped ranges.
public enum HostReadSpans {
  /// The P(ad) a step must reach for an address in its own words to anchor.
  public static let anchorThreshold = 0.9
  /// How far before a run the sponsor's name or a sponsor phrase may open the read.
  public static let lookBackSeconds = 90.0
  /// Anchor steps no further apart than this form one call-to-action run.
  static let runGapSeconds = 10.0
  /// A raw word this long after the one before it starts a sentence.
  static let sentenceGapSeconds = 1.0
  /// The sponsor is known by this many leading characters of its address ("fuseenergy.com" is
  /// "fuse"): the transcriber splits and respells the rest ("Fuse Energy").
  static let stemLength = 4

  /// A candidate per call-to-action run that has a start, in run order. `probabilities` holds
  /// P(ad) for every step of `steps`, which are `Arbiter.steps(for: transcript.transcript)`.
  public static func candidates(
    in transcript: PreparedTranscript, steps: [Arbiter.Step], probabilities: [Double],
    showTitle: String?
  ) -> [CandidateRange] {
    precondition(steps.count == probabilities.count, "One P(ad) per step")
    let raw = transcript.transcript.words
    let runs = runs(steps: steps, probabilities: probabilities, words: raw)
    guard !runs.isEmpty else { return [] }
    let phrases = SponsorPhraseStart.anchors(
      in: transcript.words, showTitle: SponsorPhraseStart.titleWords(showTitle))
    return runs.compactMap { run in
      let earliest = run.start - lookBackSeconds
      var starts: [Double] = []
      if let stem = run.stem,
        let named = raw.indices.first(where: {
          earliest <= raw[$0].start && raw[$0].start < run.end
            && PreparedTranscript.normalise(raw[$0].text).hasPrefix(stem)
        })
      {
        starts.append(raw[sentenceHead(of: named, in: raw)].start)
      }
      if let phrase = phrases.lazy.map(\.start).filter({ earliest <= $0 && $0 < run.end }).min() {
        starts.append(phrase)
      }
      guard let opening = starts.min() else { return nil }
      let start = SponsorPhraseStart.extendedBack(opening, in: transcript)
      let lastWord = raw.last { run.start <= middle($0) && middle($0) < run.end }
      let end = PlaybackEdges.extendingEnd(
        of: KeptRange(
          start: start, end: lastWord?.end ?? run.end, meanAdProbability: 0, endsItem: false),
        silences: transcript.silences
      ).end
      return end > start ? CandidateRange(start: start, end: end) : nil
    }
  }

  /// The least of a host-read span that is served once the shipped ranges are cut out of it. A
  /// sliver beside a shipped range is not worth a skip of its own.
  public static let minimumServedSeconds = 5.0

  /// What is served of `kept`, sorted by start, beside `shipped`, which is sorted and disjoint and
  /// never moves: spans that overlap become one, each loses whatever a shipped range covers, and a
  /// piece shorter than `minimumServedSeconds` is dropped. A piece that reaches its span's end
  /// keeps the span's `endsItem`.
  public static func layingOver(_ kept: [KeptRange], shipped: [TimeSpan]) -> [KeptRange] {
    var merged: [KeptRange] = []
    for range in kept {
      if let last = merged.last, range.start <= last.end {
        let later = range.end > last.end ? range : last
        merged[merged.count - 1] = KeptRange(
          start: last.start, end: later.end,
          meanAdProbability: min(last.meanAdProbability, range.meanAdProbability),
          endsItem: later.endsItem)
      } else {
        merged.append(range)
      }
    }
    return merged.flatMap { range -> [KeptRange] in
      var pieces: [TimeSpan] = []
      var start = range.start
      for span in shipped where span.end > start && span.start < range.end {
        if span.start > start { pieces.append(TimeSpan(start: start, end: span.start)) }
        start = max(start, span.end)
      }
      if start < range.end { pieces.append(TimeSpan(start: start, end: range.end)) }
      return pieces.filter { $0.end - $0.start >= minimumServedSeconds }.map {
        KeptRange(
          start: $0.start, end: $0.end, meanAdProbability: range.meanAdProbability,
          endsItem: $0.end == range.end && range.endsItem)
      }
    }
  }

  /// A call-to-action run: consecutive anchor steps, and the sponsor's stem from its last address.
  struct Run: Equatable {
    let start: Double
    let end: Double
    let stem: String?
  }

  /// Steps at or over `anchorThreshold` whose own words carry an address, grouped into runs.
  static func runs(steps: [Arbiter.Step], probabilities: [Double], words: [TranscriptWord]) -> [Run] {
    var grouped: [(start: Double, end: Double, texts: [String])] = []
    for (step, probability) in zip(steps, probabilities) where probability >= anchorThreshold {
      let text = ownWords(of: step, in: words)
      guard !addressStems(in: text).isEmpty else { continue }
      if let last = grouped.last, step.start - last.end <= runGapSeconds {
        grouped[grouped.count - 1].end = step.end
        grouped[grouped.count - 1].texts.append(text)
      } else {
        grouped.append((step.start, step.end, [text]))
      }
    }
    return grouped.map {
      Run(
        start: $0.start, end: $0.end,
        stem: addressStems(in: $0.texts.joined(separator: " ")).last.map { String($0.prefix(stemLength)) })
    }
  }

  /// The raw words whose midpoint falls in `step`. `Arbiter.Step.text` is the step with 7.5 s of
  /// context either side, which would let one address anchor three steps.
  static func ownWords(of step: Arbiter.Step, in words: [TranscriptWord]) -> String {
    words.lazy.filter { step.start <= middle($0) && middle($0) < step.end }.map(\.text)
      .joined(separator: " ")
  }

  private static func middle(_ word: TranscriptWord) -> Double { (word.start + word.end) / 2 }

  /// Addresses as the transcriber writes them: "fuseenergy.com", "fuseenergy dot com", and with a
  /// space before the dot. Run on raw words, since normalising strips the dot. An address split
  /// into separate words ("fuse energy com") is not matched: in hold-out 7's transcripts every
  /// such form ended in an ordinary word.
  private static let address = try? NSRegularExpression(
    pattern: #"([a-z][a-z0-9-]{2,})\s*(?:\.|\bdot\s+)(?:com|co\.uk|co|org|net|io|fm|ly|us|ai|me|ca)\b"#)
  private static let notNames: Set<String> = ["www", "http", "https", "the", "dot"]

  /// The name before each address in `text`, lower-cased, in order.
  static func addressStems(in text: String) -> [String] {
    guard let address else { return [] }
    let lowered = text.lowercased()
    return address.matches(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)).compactMap {
      Range($0.range(at: 1), in: lowered).map { String(lowered[$0]) }
    }.filter { !notNames.contains($0) }
  }

  /// Index of the first word of the sentence holding `words[index]`: back while the word before
  /// runs straight in and does not end a sentence.
  static func sentenceHead(of index: Int, in words: [TranscriptWord]) -> Int {
    var head = index
    while head > 0, words[head].start - words[head - 1].end < sentenceGapSeconds,
      !(words[head - 1].text.last.map { ".?!".contains($0) } ?? false)
    {
      head -= 1
    }
    return head
  }
}

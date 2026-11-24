import Foundation

/// Where a kept range starts skipping when a sponsor phrase ("This episode is brought to you
/// by…") opens the ad shortly before it. Like `PlaybackEdges`, not part of the harness port: the
/// coordinator applies it after learning, so the signature store and parity targets still see the
/// frozen rules' ranges. Harness twin: ad-harness `Scripts/research/phrase/v6.py`
/// (`phrase.py --modes v6`), forms mined from the labelled corpus; the show-name subject and the
/// coordinator's second round are `Scripts/research/phrasechain/phrasechain.py`'s `title+chain`.
///
/// The sponsor's name is the word the transcriber spells least consistently ("E Toro", "Itoro"),
/// so no shingle through it matches and a matched range starts after the lead-in; the phrase before
/// the name is stable. It only moves the start of a range the pipeline already keeps: a phrase
/// gives no end, and guessing the end is how the keyword stage failed.
public enum SponsorPhraseStart {
  /// The furthest a start may move back, from the phrase's first word to the kept range's start.
  /// The arbiter cannot catch a phrase far before an unrelated range (programme bridges score up to
  /// 0.13 on the tuning roots), so this cap is the rule's safety limit.
  public static let maximumExtensionSeconds = 90.0
  /// Consecutive phrase words, and the subject prefix before them, are under this far apart.
  static let wordGapSeconds = 1.0
  /// An open subject ("Gareth Reynolds, the Dollop") is at most this many words before "is|was".
  static let maximumOpenSubjectWords = 6
  /// Words a sentence may have before "support for" ("And now, support for…").
  static let maximumSupportLeadWords = 3
  /// "Support for … comes from" names at most this many words between the two.
  static let maximumSupportForWords = 8
  /// Words a sentence may have before "thank" or "for sponsoring".
  static let maximumSentenceLeadWords = 8
  /// Words between "our" and the thanked partner ("our brand new presenting partner").
  static let maximumThankModifiers = 3

  /// Candidate starts for one kept range.
  public struct Proposal: Sendable, Equatable {
    /// Index into the kept ranges passed to `proposals`.
    public let keptIndex: Int
    /// Earliest anchor first. The caller keeps the first whose extended range the arbiter keeps.
    public let starts: [Double]

    public init(keptIndex: Int, starts: [Double]) {
      self.keptIndex = keptIndex
      self.starts = starts
    }
  }

  private static let triggers: [[String]] = [
    ["brought", "to", "you", "by"], ["brought", "to", "us", "by"], ["sponsored", "by"], ["supported", "by"],
    ["powered", "by"],
  ]
  /// The triggers that take any short subject opening a sentence ("The Dollop is brought to you
  /// by"). The others keep the subject list: "he was supported by his second wife" is programme.
  private static let openSubjectTriggers: [[String]] = [
    ["brought", "to", "you", "by"], ["brought", "to", "us", "by"],
  ]
  private static let thankObjects: [[String]] = [
    ["partner"], ["partners"], ["sponsor"], ["sponsors"], ["friends", "at"], ["favourite", "companies"],
    ["favorite", "companies"],
  ]
  private static let sponsorWords: [[String]] = [
    ["word", "from", "our", "sponsor"], ["word", "from", "our", "sponsors"],
    ["words", "from", "our", "sponsor"], ["words", "from", "our", "sponsors"],
  ]
  private static let subjects: Set<String> = ["episode", "podcast", "show", "programme", "program", "series"]
  private static let determiners: Set<String> = ["this", "todays", "the", "our"]

  /// For each kept range a sponsor phrase opens within `maximumExtensionSeconds`, its candidate
  /// starts. A phrase anchors when its start lies in no kept range, the range is the first kept
  /// range starting at or after the phrase's last word, and no tombstoned shingle overlaps the
  /// stretch the new start adds (an Undo of an extended range must not be rebuilt). `showTitle` is
  /// the show's own name, which may stand as a phrase's subject.
  public static func proposals(
    for kept: [KeptRange], in transcript: PreparedTranscript, showTitle: String?,
    isTombstoned: (UInt64) -> Bool
  ) -> [Proposal] {
    let byStart = kept.indices.sorted { kept[$0].start < kept[$1].start }
    var starts: [Int: [Double]] = [:]
    for anchor in anchors(in: transcript.words, showTitle: titleWords(showTitle)) {
      guard kept.allSatisfy({ !($0.start <= anchor.start && anchor.start < $0.end) }),
        let index = byStart.first(where: { kept[$0].start >= anchor.phraseEnd })
      else { continue }
      let rangeStart = kept[index].start
      guard rangeStart - anchor.start <= maximumExtensionSeconds else { continue }
      let start = extendedBack(anchor.start, in: transcript)
      guard
        !transcript.shingles.contains(where: {
          $0.start < rangeStart && $0.end > start && isTombstoned($0.hash)
        })
      else { continue }
      starts[index, default: []].append(start)
    }
    return starts.keys.sorted().map { Proposal(keptIndex: $0, starts: starts[$0] ?? []) }
  }

  /// Every phrase, in transcript order: `start` is the head of its sentence, `phraseEnd` the end of
  /// its last word, and every word between runs into the next.
  /// - "[and] [now] [a] [quick] word(s) from our sponsor(s)";
  /// - "[det] episode|podcast|… is|was [also|proudly]" before any trigger;
  /// - a sentence's first 1-6 words before "is|was [also|proudly] brought to you|us by";
  /// - the show's name opening a sentence before "is|was [also|proudly]" and any trigger;
  /// - "support for <1-8 words> comes|come from", after at most 3 words of its sentence;
  /// - "thank [you to] our|one of our [≤ 3 words] partner|sponsor|friends at|favourite companies"
  ///   and "for sponsoring", after at most 8 words of their sentence.
  ///
  /// Mid-sentence phrases do not anchor: "…and it's brought to you by our friends at Chevy" is the
  /// host's segue line, and the corpus has bare "sponsored by" and "our sponsors" in programme.
  static func anchors(
    in words: [PreparedTranscript.Word], showTitle: [String]
  ) -> [(start: Double, phraseEnd: Double)] {
    words.indices.compactMap { i in
      anchor(at: i, in: words, showTitle: showTitle).map { (words[$0.head].start, words[$0.end].end) }
    }
  }

  /// A show title as transcript words, without a leading "the" ("rest", "is", "money").
  static func titleWords(_ title: String?) -> [String] {
    let words = (title ?? "").split(whereSeparator: \.isWhitespace).map {
      PreparedTranscript.normalise(String($0))
    }.filter { !$0.isEmpty }
    return words.first == "the" ? Array(words.dropFirst()) : words
  }

  /// The first and last word of the phrase whose trigger is `words[i]`, by the first form matching.
  private static func anchor(
    at i: Int, in words: [PreparedTranscript.Word], showTitle: [String]
  ) -> (head: Int, end: Int)? {
    if let length = match(sponsorWords, at: i, in: words) {
      return (sponsorHead(i, in: words), i + length - 1)
    }
    if let length = match(triggers, at: i, in: words), let head = subjectHead(i, in: words) {
      return (head, i + length - 1)
    }
    if let length = match(openSubjectTriggers, at: i, in: words), let head = openSubjectHead(i, in: words) {
      return (head, i + length - 1)
    }
    if let length = match(triggers, at: i, in: words), let head = titleHead(i, title: showTitle, in: words) {
      return (head, i + length - 1)
    }
    if match([["support", "for"]], at: i, in: words) != nil,
      let head = sentenceHead(i, lead: maximumSupportLeadWords, in: words),
      let end = comesFromEnd(i, in: words)
    {
      return (head, end)
    }
    if words[i].text == "thank", let head = sentenceHead(i, lead: maximumSentenceLeadWords, in: words),
      let end = thankEnd(i, in: words)
    {
      return (head, end)
    }
    if match([["for", "sponsoring"]], at: i, in: words) != nil,
      let head = sentenceHead(i, lead: maximumSentenceLeadWords, in: words)
    {
      return (head, i + 1)
    }
    return nil
  }

  private static func match(_ phrases: [[String]], at i: Int, in words: [PreparedTranscript.Word]) -> Int? {
    for phrase in phrases where i + phrase.count <= words.count {
      guard zip(phrase, words[i..<(i + phrase.count)]).allSatisfy({ $0 == $1.text }),
        (i..<(i + phrase.count - 1)).allSatisfy({ joined($0, in: words) })
      else { continue }
      return phrase.count
    }
    return nil
  }

  /// Whether `words[j]` runs straight into the next word.
  private static func joined(_ j: Int, in words: [PreparedTranscript.Word]) -> Bool {
    j >= 0 && j + 1 < words.count && words[j + 1].start - words[j].end < wordGapSeconds
  }

  private static func joined(
    _ j: Int, in words: [PreparedTranscript.Word], to choices: Set<String>
  ) -> Bool {
    joined(j, in: words) && choices.contains(words[j].text)
  }

  /// "[and] [now] [a|few|some|quick] [a|quick] word from our sponsors": the earliest of those
  /// words.
  private static func sponsorHead(_ i: Int, in words: [PreparedTranscript.Word]) -> Int {
    var j = i
    if joined(j - 1, in: words, to: ["a", "few", "some", "quick"]) {
      j -= 1
      if joined(j - 1, in: words, to: ["a", "quick"]) { j -= 1 }
    }
    if joined(j - 1, in: words, to: ["now"]) {
      j -= 1
      if joined(j - 1, in: words, to: ["and"]) { j -= 1 }
    }
    return j
  }

  /// "[this|todays|the|our] episode|podcast|… is|was [also|proudly]" before a trigger: the index of
  /// its first word, or nil when there is no subject (strict mode leaves a bare phrase alone).
  private static func subjectHead(_ i: Int, in words: [PreparedTranscript.Word]) -> Int? {
    guard var j = verbHead(i, in: words), joined(j - 1, in: words, to: subjects) else { return nil }
    j -= 1
    if joined(j - 1, in: words, to: determiners) { j -= 1 }
    return j
  }

  /// "<1-6 words opening a sentence> is|was [also|proudly]" before a trigger: the sentence's first
  /// word, or nil.
  private static func openSubjectHead(_ i: Int, in words: [PreparedTranscript.Word]) -> Int? {
    guard let verb = verbHead(i, in: words), joined(verb - 1, in: words) else { return nil }
    return sentenceHead(verb - 1, lead: maximumOpenSubjectWords - 1, in: words)
  }

  /// "[the] <show title> is|was [also|proudly]" opening a sentence before a trigger: the index of
  /// its first word, or nil. Unlike an open subject, the show's own name takes every trigger.
  private static func titleHead(_ i: Int, title: [String], in words: [PreparedTranscript.Word]) -> Int? {
    guard title.isEmpty == false, let verb = verbHead(i, in: words), verb >= title.count else { return nil }
    var head = verb - title.count
    guard (head..<verb).allSatisfy({ words[$0].text == title[$0 - head] && joined($0, in: words) }) else {
      return nil
    }
    if words[head].opensSentence == false, joined(head - 1, in: words, to: ["the"]) { head -= 1 }
    return words[head].opensSentence ? head : nil
  }

  /// The index of "is|was" before a trigger at `i`, over an optional "also|proudly".
  private static func verbHead(_ i: Int, in words: [PreparedTranscript.Word]) -> Int? {
    var j = i
    if joined(j - 1, in: words, to: ["also", "proudly"]) { j -= 1 }
    guard joined(j - 1, in: words, to: ["is", "was"]) else { return nil }
    return j - 1
  }

  /// The word opening `words[i]`'s sentence, at most `lead` joined words before it, or nil.
  private static func sentenceHead(_ i: Int, lead: Int, in words: [PreparedTranscript.Word]) -> Int? {
    var k = i
    while !words[k].opensSentence {
      guard i - k < lead, joined(k - 1, in: words) else { return nil }
      k -= 1
    }
    return k
  }

  /// The index of "from" in "support for <1-8 words> comes|come from", with "support" at `i`.
  private static func comesFromEnd(_ i: Int, in words: [PreparedTranscript.Word]) -> Int? {
    let first = i + 2
    let last = min(first + maximumSupportForWords, words.count - 2)
    guard joined(i + 1, in: words), first < last else { return nil }
    for m in (first + 1)...last {
      guard joined(m - 1, in: words) else { return nil }
      if ["comes", "come"].contains(words[m].text), words[m + 1].text == "from", joined(m, in: words) {
        return m + 1
      }
    }
    return nil
  }

  /// The index of the last word of "thank [you to] our|one of our [≤ 3 words] partner|…", with
  /// "thank" at `i`.
  private static func thankEnd(_ i: Int, in words: [PreparedTranscript.Word]) -> Int? {
    func at(_ k: Int, _ text: String) -> Bool {
      k < words.count && words[k].text == text && joined(k - 1, in: words)
    }
    var j = i + 1
    if at(j, "you"), at(j + 1, "to") { j += 2 }
    if at(j, "our") {
      j += 1
    } else if at(j, "one"), at(j + 1, "of"), at(j + 2, "our") {
      j += 3
    } else {
      return nil
    }
    for skip in 0...maximumThankModifiers {
      let k = j + skip
      guard k < words.count, skip == 0 || joined(k - 1, in: words) else { return nil }
      if let object = thankObjects.first(where: { object in object.indices.allSatisfy { at(k + $0, object[$0]) } }) {
        return k + object.count - 1
      }
    }
    return nil
  }

  /// `start` moved back over wordless audio to the end of a silence ending within
  /// `RepetitionStage.extensionSeconds`. Unlike the repetition stage's own rule, which can move a
  /// start up to 0.5 s later, the result is never later than `start`, or it would cut the phrase.
  static func extendedBack(_ start: Double, in transcript: PreparedTranscript) -> Double {
    guard
      let silence = transcript.silences.last(where: {
        $0.end <= start + 0.5 && start - $0.end <= RepetitionStage.extensionSeconds
      }),
      !transcript.words.contains(where: { silence.end < $0.end && $0.start < start - 0.05 })
    else { return start }
    return min(silence.end, start)
  }
}

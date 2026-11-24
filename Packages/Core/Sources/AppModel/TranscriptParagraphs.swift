import Persistence

/// A transcript's words as sentences and paragraphs, for reading.
///
/// A sentence ends at a word whose last character, after any closing quotes or brackets, is `.`,
/// `?`, `!` or `…`. This matches `PreparedTranscript.endsSentence` in AdSkip, which stays internal
/// to that module. A paragraph ends at a sentence boundary followed by a gap of two seconds or
/// more, or after `maximumSentencesPerParagraph` sentences, so a monologue does not become one
/// block. A paragraph never holds sentences from inside and outside an ad, or from two ads: it
/// breaks at each ad edge, so an ad is one or more whole paragraphs. A sentence is in an ad when
/// its midpoint is inside the range.
public struct TranscriptParagraphs: Sendable, Equatable {
  public struct Sentence: Sendable, Equatable {
    public let text: String
    /// File time of the first word's start, in seconds.
    public let start: Double
    /// File time of the last word's end, in seconds.
    public let end: Double
  }

  public struct Paragraph: Sendable, Equatable {
    public let sentences: [Sentence]
    /// The index of the first sentence in `TranscriptParagraphs.sentences`.
    public let firstSentenceIndex: Int
    /// The ad the paragraph's sentences are in, if any.
    public let ad: TranscriptAdRange?
    /// Whether this is the first paragraph of its ad, which is where the view draws the ad's header.
    public let startsAd: Bool

    /// Stable across a re-split by ad ranges, unlike the paragraph's offset.
    public var id: Int { firstSentenceIndex }

    /// File time of the first word, in seconds.
    public var start: Double { sentences.first?.start ?? 0 }
  }

  public static let paragraphGap: Double = 2
  public static let maximumSentencesPerParagraph = 6

  public let sentences: [Sentence]
  public let paragraphs: [Paragraph]

  public static let empty = TranscriptParagraphs(words: [])

  public init(words: [StoredTranscriptWord], adRanges: [TranscriptAdRange] = []) {
    sentences = Self.sentences(from: words)
    paragraphs = Self.paragraphs(from: sentences, adRanges: adRanges)
  }

  /// The last sentence to have started by `time`, or nil before the first.
  public func sentenceIndex(at time: Double) -> Int? {
    var low = 0
    var high = sentences.count
    while low < high {
      let middle = (low + high) / 2
      if sentences[middle].start <= time { low = middle + 1 } else { high = middle }
    }
    return low == 0 ? nil : low - 1
  }

  /// How early a paragraph may start and still count as inside the chapter that follows: the
  /// recogniser's first word can lead a chapter mark by a fraction of a second.
  public static let chapterLeadTolerance: Double = 1

  /// Chapter titles keyed by the paragraph each one heads: the first paragraph that starts inside
  /// that chapter. Untitled chapters, and chapters no paragraph starts in, head nothing.
  public func chapterHeadings(_ chapters: [(start: Double, title: String)]) -> [Int: String] {
    let titled =
      chapters
      .map { (start: $0.start, title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines)) }
      .filter { $0.title.isEmpty == false }
      .sorted { $0.start < $1.start }
    var headings: [Int: String] = [:]
    var previous: Int?
    for (index, paragraph) in paragraphs.enumerated() {
      let chapter = titled.lastIndex { $0.start <= paragraph.start + Self.chapterLeadTolerance }
      if let chapter, chapter != previous { headings[index] = titled[chapter].title }
      previous = chapter
    }
    return headings
  }

  /// The paragraph that holds a sentence, or nil when there is no such sentence.
  public func paragraphIndex(containingSentence sentence: Int) -> Int? {
    guard sentences.indices.contains(sentence) else { return nil }
    var low = 0
    var high = paragraphs.count
    while low < high {
      let middle = (low + high) / 2
      if paragraphs[middle].firstSentenceIndex <= sentence { low = middle + 1 } else { high = middle }
    }
    return low - 1
  }

  // MARK: - Building

  private static func sentences(from words: [StoredTranscriptWord]) -> [Sentence] {
    var result: [Sentence] = []
    var text = ""
    var start = 0.0
    var end = 0.0
    for word in words {
      let piece = word.text.trimmingCharacters(in: .whitespaces)
      guard piece.isEmpty == false else { continue }
      if text.isEmpty {
        start = word.start
      } else if let first = piece.first, attachesToPrevious.contains(first) == false {
        text.append(" ")
      }
      text.append(piece)
      end = word.end
      if endsSentence(piece) {
        result.append(Sentence(text: text, start: start, end: end))
        text = ""
      }
    }
    if text.isEmpty == false { result.append(Sentence(text: text, start: start, end: end)) }
    return result
  }

  private static func paragraphs(
    from sentences: [Sentence], adRanges: [TranscriptAdRange]
  ) -> [Paragraph] {
    var result: [Paragraph] = []
    var current: [Sentence] = []
    var currentAd: Int?
    var firstIndex = 0
    func close() {
      guard current.isEmpty == false else { return }
      let ad = currentAd.map { adRanges[$0] }
      let continues = currentAd != nil && result.last?.ad == ad
      result.append(
        Paragraph(
          sentences: current, firstSentenceIndex: firstIndex, ad: ad, startsAd: ad != nil && !continues))
    }
    for (index, sentence) in sentences.enumerated() {
      let ad = adIndex(of: sentence, in: adRanges)
      if let last = current.last,
        sentence.start - last.end >= paragraphGap || current.count >= maximumSentencesPerParagraph
          || ad != currentAd
      {
        close()
        current = []
        firstIndex = index
      }
      current.append(sentence)
      currentAd = ad
    }
    close()
    return result
  }

  /// The first range holding the sentence's midpoint.
  private static func adIndex(of sentence: Sentence, in ranges: [TranscriptAdRange]) -> Int? {
    let middle = (sentence.start + sentence.end) / 2
    return ranges.firstIndex { $0.start <= middle && middle < $0.end }
  }

  /// Punctuation the recogniser may emit as a word of its own, written against the word before.
  private static let attachesToPrevious: Set<Character> = [
    ",", ".", "?", "!", "\u{2026}", ";", ":", ")", "]", "\u{201D}", "\u{2019}",
  ]

  private static func endsSentence(_ text: String) -> Bool {
    let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]"]
    guard let last = text.reversed().first(where: { !closers.contains($0) }) else { return false }
    return [".", "?", "!", "\u{2026}"].contains(last)
  }
}

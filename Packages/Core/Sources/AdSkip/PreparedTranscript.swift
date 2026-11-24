import Foundation

/// A transcript cut into the repetition stage's segments and shingles (`repeatall.py` `load_copy`
/// and `shingles`).
public struct PreparedTranscript: Sendable {
  /// A normalised, non-empty word.
  public struct Word: Sendable, Equatable {
    public let text: String
    public let start: Double
    public let end: Double
    /// The transcript's first word, one after a raw word ending a sentence (`.`, `?`, `!`), or the
    /// first of a transcribed stretch. Normalising drops the punctuation, so this keeps the one
    /// boundary the sponsor phrase needs. A stretch starts wherever its window fell, so the last
    /// word before it, often cut off mid-sentence minutes earlier, says nothing about a sentence.
    public let opensSentence: Bool
  }

  /// An 8-word shingle inside one segment: its hash, the first word's start and the last word's end.
  public struct Shingle: Sendable, Equatable {
    public let hash: UInt64
    public let start: Double
    public let end: Double
    /// Index into `segments`.
    public let segment: Int
    /// Index into `words` of the shingle's first word.
    public let firstWord: Int
  }

  public static let shingleLength = 8
  /// A gap between consecutive normalised words of at least this many seconds starts a segment.
  public static let seamSeconds = 2.0

  public let transcript: Transcript
  public let silences: [Silence]
  /// Normalised words with empties dropped, in transcript order.
  public let words: [Word]
  /// Index ranges into `words`.
  public let segments: [Range<Int>]
  /// Every shingle, segment by segment, in word order.
  public let shingles: [Shingle]

  /// `stretchStarts` are where transcribed stretches begin; empty for a whole-file transcript.
  public init(transcript: Transcript, silences: [Silence], stretchStarts: [Double] = []) {
    var words: [Word] = []
    var segments: [Range<Int>] = []
    var segmentStart = 0
    var opensSentence = true
    for raw in transcript.words {
      let text = PreparedTranscript.normalise(raw.text)
      let endsSentence = PreparedTranscript.endsSentence(raw.text)
      if text.isEmpty {
        if endsSentence { opensSentence = true }
        continue
      }
      if let previous = words.last, raw.start - previous.end >= PreparedTranscript.seamSeconds {
        segments.append(segmentStart..<words.count)
        segmentStart = words.count
      }
      if let previous = words.last, stretchStarts.contains(where: { previous.end <= $0 && $0 < raw.end }) {
        opensSentence = true
      }
      words.append(Word(text: text, start: raw.start, end: raw.end, opensSentence: opensSentence))
      opensSentence = endsSentence
    }
    if !words.isEmpty { segments.append(segmentStart..<words.count) }

    let length = PreparedTranscript.shingleLength
    var shingles: [Shingle] = []
    for (segmentIndex, segment) in segments.enumerated() where segment.count >= length {
      for first in segment.lowerBound...(segment.upperBound - length) {
        let window = words[first..<(first + length)]
        shingles.append(
          Shingle(
            hash: ShingleHash.hash(window.lazy.map(\.text)),
            start: words[first].start, end: words[first + length - 1].end,
            segment: segmentIndex, firstWord: first))
      }
    }
    self.transcript = transcript
    self.silences = silences
    self.words = words
    self.segments = segments
    self.shingles = shingles
  }

  /// The distinct shingle hashes, for episode grouping and the library index.
  public var shingleHashes: Set<UInt64> {
    Set(shingles.lazy.map(\.hash))
  }

  /// Whether raw word text ends a sentence: its last character, after any closing quotes or
  /// brackets, is `.`, `?`, `!` or `…`.
  static func endsSentence(_ text: String) -> Bool {
    let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]"]
    guard let last = text.trimmingCharacters(in: .whitespaces).reversed().first(where: { !closers.contains($0) })
    else { return false }
    return [".", "?", "!", "\u{2026}"].contains(last)
  }

  /// `re.sub(r"[^a-z0-9]", "", word.lower())`: lower-case, then keep only ASCII letters and digits.
  public static func normalise(_ text: String) -> String {
    var result = String.UnicodeScalarView()
    for scalar in text.lowercased().unicodeScalars {
      switch scalar.value {
      case 0x30...0x39, 0x61...0x7A: result.append(scalar)
      default: break
      }
    }
    return String(result)
  }
}

/// The shingle hash. Stable across processes and releases: it is persisted in the signature store.
/// Swift's `Hasher` is seeded per process and must never be used here.
public enum ShingleHash {
  /// 64-bit FNV-1a over the UTF-8 bytes of `words` joined by single spaces.
  public static func hash(_ words: some Sequence<String>) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    var first = true
    for word in words {
      if !first {
        hash = (hash ^ 0x20) &* 0x100_0000_01b3
      }
      first = false
      for byte in word.utf8 {
        hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
      }
    }
    return hash
  }
}

import Foundation
import Persistence

/// The paragraphs a show repeats across its recent episodes: membership plugs, socials, credits
/// with no divider or ad wording for `PodcastShowNotes` to catch on one episode alone. Feed it the
/// show's recent descriptions, newest first, and it answers whether a paragraph is one of them.
///
/// Matching is approximate, since publishers keep editing boilerplate. Each paragraph is reduced
/// to its set of adjacent word pairs after case, diacritics, width, punctuation and whitespace
/// fold away, and two match when those sets overlap by at least half (Jaccard). Episode-specific
/// paragraphs sit far below that (the closest pair across real feeds, a six-part series sharing
/// subject and hosts, scored 0.12), so the recurrence threshold, not the matching, keeps a
/// two-part episode's shared paragraph visible. `FeedHTML` strips links to their text, so
/// per-episode tracking URLs never split a match.
public struct ShowNotesBoilerplate: Sendable, Equatable {
  public static let none = ShowNotesBoilerplate(samples: [], sampleCount: 0)

  /// How many recent episodes are sampled. Enough for a weekly show's standing plugs to clear the
  /// threshold, few enough that a card open stays cheap.
  public static let window = 20
  /// Below this many sampled episodes, recurrence is too weak a signal to hide anything on.
  public static let minimumSampleCount = 5

  public let sampleCount: Int
  /// Per sampled description, the word-pair set of each distinct paragraph.
  private let samples: [[Set<String>]]

  private init(samples: [[Set<String>]], sampleCount: Int) {
    self.samples = samples
    self.sampleCount = sampleCount
  }

  /// `descriptions` are raw feed text or HTML, newest first; anything past `window` is ignored.
  public init(descriptions: [String]) {
    let sample = descriptions.prefix(Self.window)
    guard sample.count >= Self.minimumSampleCount else {
      self = .none
      return
    }

    samples = sample.map { description in
      guard let text = FeedHTML.paragraphs(description) else { return [] }
      let paragraphs = text.components(separatedBy: "\n\n").prefix(Self.maximumParagraphs)
      return Array(Set(paragraphs.compactMap(Self.wordPairs)))
    }
    sampleCount = sample.count
  }

  public func contains(paragraph: String) -> Bool {
    guard samples.isEmpty == false, let pairs = Self.wordPairs(paragraph) else { return false }

    // A quarter of the window, and never fewer than three: at 20 episodes a standing plug in 10 to
    // 18 of them folds, as does a month-long sponsor read on a daily show; a two-part episode's
    // shared paragraph (2 of 20) and a one-off sponsor read (1 of 20) stay visible.
    let threshold = max(3, Int((Double(sampleCount) * 0.25).rounded(.up)))
    var matches = 0
    for description in samples where description.contains(where: { Self.isMatch(pairs, $0) }) {
      matches += 1
      if matches >= threshold { return true }
    }
    return false
  }

  /// Bounds the work a pathological description can cause; real show notes run to dozens.
  private static let maximumParagraphs = 64
  private static let minimumKeyLength = 12
  private static let minimumOverlap = 0.5

  private static func isMatch(_ lhs: Set<String>, _ rhs: Set<String>) -> Bool {
    let shared = lhs.count <= rhs.count ? lhs.intersection(rhs).count : rhs.intersection(lhs).count
    return Double(shared) >= minimumOverlap * Double(lhs.count + rhs.count - shared)
  }

  /// `nil` for a paragraph too short to judge. A one-word paragraph is its own single "pair".
  static func wordPairs(_ paragraph: String) -> Set<String>? {
    let folded = paragraph.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    let words = folded.split { $0.isLetter == false && $0.isNumber == false }
    guard words.joined(separator: " ").count >= minimumKeyLength else { return nil }
    guard words.count > 1 else { return [String(words[0])] }
    return Set(zip(words, words.dropFirst()).map { "\($0) \($1)" })
  }
}
